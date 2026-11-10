// SunSynk official API (openapi.sunsynk.net) — auth + fetch, per linked account.
//
// Replaces the private-API flow (RSA-encrypted password → /oauth/token/new on
// api.sunsynk.net). The official gateway is Alibaba Cloud API Gateway: every request
// is HMAC-SHA256 signed with an app secret, then carries a per-user bearer token.
//
// Two auth layers, two jobs:
//   * app key + signature   — identifies the application to the gateway
//   * bearer token          — identifies which SunSynk user's plants to return
//
// Multi-tenant: one row in private.sunsynk_accounts per linked SunSynk login. The
// refresh token lives in Vault; the access token (a 7-day JWT) is cached on the row.
// The user's password is never stored — linkAccount() exchanges it and drops it.
//
// Verified behaviour (3 Sep 2026):
//   * a wrong secret and a wrong key both return "Invalid AppKey" — indistinguishable
//   * x-ca-key must NOT be listed in X-Ca-Signature-Headers, or signing fails
//   * refresh returns the SAME refresh token (static, reusable, not rotating)
//   * a password change kills the refresh token, but the failure is silent:
//     HTTP 200, msg "Success", empty data. Check data.access_token, never msg.
//   * the access token (stateless JWT) keeps working until its own expiry
//   * there is no read-only scope; every token is scope=all
import { createClient } from "jsr:@supabase/supabase-js@2.118.0";
import { createHash, createHmac } from "node:crypto";
import { type InverterInfo, num, pick } from "./extract.ts";
import { noteError } from "./errors.ts";

const API_BASE = Deno.env.get("SUNSYNK_API_BASE") ?? "https://openapi.sunsynk.net";
// Fake logins (name@mock, SOLAR-270) go to the mock: locally the mock server is API_BASE
// already; in production the mock-sunsynk function, which only testers can link
// (link-sunsynk). Its tokens are "at:<login>" and "rt:<login>", unlike any SunSynk token.
const MOCK_BASE = Deno.env.get("SUNSYNK_API_BASE") ?? `${Deno.env.get("SUPABASE_URL")}/functions/v1/mock-sunsynk`;
const baseFor = (loginOrToken: string) => (loginOrToken.endsWith("@mock") ? MOCK_BASE : API_BASE);
const APP_KEY = Deno.env.get("SUNSYNK_APP_KEY") ?? "";
const APP_SECRET = Deno.env.get("SUNSYNK_APP_SECRET") ?? "";
const CLIENT_ID = "openapi";
// Refresh the access token this many seconds before SunSynk says it expires.
const EXPIRY_MARGIN_S = 300;

if (!APP_KEY || !APP_SECRET) {
  console.warn("SUNSYNK_APP_KEY / SUNSYNK_APP_SECRET not set — every request will fail");
}

export const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// The gateway's verify_jwt lets through the publishable key and any user's
// session, so poll / recover / sync-plant-energy check the caller themselves.
// pg_cron and plant_bootstrap_kick send the vault service_role_key, an
// sb_secret_ key; the platform injects every secret key as SUPABASE_SECRET_KEYS
// (JSON, by name). The legacy service role JWT is accepted too (local stack).
const SERVER_KEYS = new Set(
  [
    ...Object.values(JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}") as Record<string, string>),
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  ].filter((k): k is string => !!k),
);

/** 401 response unless the bearer is one of the project's server keys; null when allowed. */
export function denyUnlessServer(req: Request): Response | null {
  const got = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (got && SERVER_KEYS.has(got)) return null;
  return new Response(JSON.stringify({ error: "unauthorized" }), {
    status: 401,
    headers: { "Content-Type": "application/json" },
  });
}

export type Account = {
  id: string;
  user_id: string;
  sunsynk_username: string;
  access_token: string | null;
  access_expires_at: number | null;
};

export type TokenSet = { access_token: string; refresh_token: string; expires_in: number };

/**
 * The company login owners share their plant to, as Visitor (SOLAR-310). One stored login
 * reads every shared plant; a plant is polled only once an owner has claimed it.
 */
export const SHARE_USERNAME = (Deno.env.get("SUNSYNK_SHARE_USERNAME") ?? "").trim();
export const isShareAccount = (acc: Pick<Account, "sunsynk_username">) =>
  !!SHARE_USERNAME && acc.sunsynk_username.toLowerCase() === SHARE_USERNAME.toLowerCase();

/** SunSynk refused the username or password (tokenLogin). */
export class LoginRejected extends Error {}

/**
 * The token endpoint failed (timeout, 5xx, network): we could not sign in, and SunSynk
 * said nothing about the login or the inverter. poll leaves the login out of its email
 * outcomes, so 30 min of it never reads as "inverter stopped sending" (SOLAR-451).
 */
export class SignInFailed extends Error {}

/** Thrown when an account's refresh token is dead; the poller marks it needs_relink. */
export class RelinkNeeded extends Error {
  constructor(public accountId: string, reason: string) {
    super(`account ${accountId} needs re-link: ${reason}`);
  }
}

// ---------------------------------------------------------------------------
// Gateway signing (Alibaba Cloud API Gateway, HMAC-SHA256)
// ---------------------------------------------------------------------------

/** Path with its query string sorted by key — the gateway canonicalises the same way. */
function canonicalUrl(pathWithQuery: string): string {
  const [path, qs] = pathWithQuery.split("?");
  if (!qs) return path;
  const pairs = [...new URLSearchParams(qs).entries()].sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);
  return `${path}?${pairs.map(([k, v]) => `${k}=${v}`).join("&")}`;
}

function signedHeaders(method: string, pathWithQuery: string, body?: string, bearer?: string): Record<string, string> {
  const accept = "application/json";
  const contentType = body ? "application/json" : "";
  const contentMd5 = body ? createHash("md5").update(body, "utf8").digest("base64") : "";

  // Only nonce + timestamp are folded into the signature. Adding x-ca-key here
  // makes the gateway reject the request as "Invalid AppKey".
  const signed: Record<string, string> = {
    "x-ca-nonce": crypto.randomUUID(),
    "x-ca-timestamp": String(Date.now()),
  };
  const keys = Object.keys(signed).sort();
  const stringToSign =
    `${method}\n${accept}\n${contentMd5}\n${contentType}\n\n` +
    keys.map((k) => `${k}:${signed[k]}`).join("\n") + "\n" +
    canonicalUrl(pathWithQuery);

  const h: Record<string, string> = {
    Accept: accept,
    ...(body ? { "Content-Type": contentType, "Content-MD5": contentMd5 } : {}),
    ...signed,
    "X-Ca-Key": APP_KEY,
    "X-Ca-Signature": createHmac("sha256", APP_SECRET).update(stringToSign, "utf8").digest("base64"),
    "X-Ca-Signature-Headers": keys.join(","),
  };
  if (bearer) h.Authorization = `Bearer ${bearer}`;
  return h;
}

// ---------------------------------------------------------------------------
// Token endpoints
// ---------------------------------------------------------------------------

async function postToken(payload: Record<string, string>): Promise<any> {
  const body = JSON.stringify(payload);
  const t0 = Date.now();
  let res: Response;
  try {
    res = await fetch(`${baseFor(payload.username ?? payload.refresh_token ?? "")}/oauth/token`, {
      method: "POST",
      headers: signedHeaders("POST", "/oauth/token", body),
      body,
    });
  } catch (e) {
    tallyCall("/oauth/token", failResult(e), Date.now() - t0);
    sunsynkFailed("/oauth/token", failResult(e), e);
    throw e;
  }
  tallyCall("/oauth/token", resultOf(res), Date.now() - t0);
  const gatewayErr = res.headers.get("x-ca-error-message");
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = new Error(`token endpoint HTTP ${res.status}: ${gatewayErr ?? json?.msg ?? ""}`);
    sunsynkFailed("/oauth/token", resultOf(res), e);
    throw e;
  }
  return json;
}

/**
 * Exchange a SunSynk username + password for tokens. The password exists only in
 * this call's arguments and the outbound request body; it is not logged, stored
 * or returned.
 */
export async function tokenLogin(username: string, password: string): Promise<TokenSet> {
  const json = await postToken({ username, password, grant_type: "password", client_id: CLIENT_ID });
  const d = json?.data;
  if (!d?.access_token || !d?.refresh_token) {
    // Bad credentials come back as a non-Success msg; surface it without echoing input.
    throw new LoginRejected(`login rejected: ${json?.msg ?? "no token in response"}`);
  }
  return { access_token: d.access_token, refresh_token: d.refresh_token, expires_in: Number(d.expires_in ?? 604800) };
}

/**
 * Refresh. Returns null when the refresh token is dead — which SunSynk reports as
 * HTTP 200 / msg "Success" / empty data, not as an error.
 */
export async function tokenRefresh(refreshToken: string): Promise<TokenSet | null> {
  const json = await postToken({ grant_type: "refresh_token", refresh_token: refreshToken, client_id: CLIENT_ID });
  const d = json?.data;
  if (!d?.access_token) return null;
  return {
    access_token: d.access_token,
    refresh_token: d.refresh_token ?? refreshToken,
    expires_in: Number(d.expires_in ?? 604800),
  };
}

const expiresAt = (expiresIn: number) => Date.now() + Math.max(60, expiresIn - EXPIRY_MARGIN_S) * 1000;

// ---------------------------------------------------------------------------
// Per-account token management
// ---------------------------------------------------------------------------

async function rpc<T = any>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

/** A valid access token for this account, refreshing if needed. Throws RelinkNeeded. */
async function accessTokenFor(acc: Account, force = false): Promise<string> {
  if (!force && acc.access_token && acc.access_expires_at && Date.now() < Number(acc.access_expires_at)) {
    return acc.access_token;
  }
  const refresh = await rpc<string | null>("account_refresh_get", { p_account: acc.id });
  if (!refresh) throw new RelinkNeeded(acc.id, "no refresh token stored");

  // The share login (SOLAR-310) has its password in a secret: sign in again rather than wait for a person.
  const sharePw = isShareAccount(acc) ? Deno.env.get("SUNSYNK_SHARE_PASSWORD") : undefined;
  let t: TokenSet | null;
  try {
    t = await tokenRefresh(refresh);
    // Only SunSynk refusing the password stops it; a timeout or 5xx is retried next minute (SOLAR-451).
    if (!t && sharePw) t = await tokenLogin(SHARE_USERNAME, sharePw).catch((e) => { if (e instanceof LoginRejected) return null; throw e; });
  } catch (e) {
    throw new SignInFailed(`account ${acc.id} sign-in failed: ${e instanceof Error ? e.message : e}`);
  }
  if (!t) throw new RelinkNeeded(acc.id, "refresh token rejected (password changed or revoked)");

  const exp = expiresAt(t.expires_in);
  await rpc("account_access_set", { p_account: acc.id, p_access: t.access_token, p_expires: exp });
  if (t.refresh_token !== refresh) {
    await rpc("account_refresh_set", { p_account: acc.id, p_refresh: t.refresh_token });
  }
  acc.access_token = t.access_token;
  acc.access_expires_at = exp;
  return t.access_token;
}

// Rate limiting. SunSynk's gateway answers a burst with 429 (and sometimes 403) and
// recovers within a second or two. Retry a couple of times with a growing wait
// before giving the minute up for this account; the shard stagger in 0030 keeps
// this the exception rather than the rule.
const RATE_LIMIT_RETRIES = 2;
const RATE_LIMIT_BACKOFF_MS = 1500;
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * SunSynk requests made per account since this isolate started, retries included.
 * The poller reports the per-minute delta so the "fewer calls" claim is measurable
 * from the cron log rather than assumed.
 */
export const apiCallCounts = new Map<string, number>();
const countCall = (acc: Account) => apiCallCounts.set(acc.id, (apiCallCounts.get(acc.id) ?? 0) + 1);

/**
 * Every SunSynk request by data type and result, with response times (SOLAR-468). The
 * data type is the path without ids, serials and dates ("/inverter/{sn}/realtime/input"
 * → "inverter/realtime/input"). Each function saves the counts with saveCallTally.
 */
type CallTally = { kind: string; result: string; calls: number; ms: number; ms_max: number };
const callTally = new Map<string, CallTally>();
const kindOf = (pathname: string) =>
  pathname.split("?")[0].split("/").filter((s) => s && !/\d/.test(s)).join("/") || "other";
// The gateway also answers 403 for "this app key may not call that path", which
// no amount of waiting fixes; only treat a 403 as throttling when its message
// says so. (Survey 2026-09-05: /plant/{id}/realtime is a plain 403 on this key.)
const throttled = (r: Response) =>
  r.status === 429 ||
  (r.status === 403 && /throttl|quota|limit/i.test(r.headers.get("x-ca-error-message") ?? ""));
const resultOf = (r: Response) =>
  r.ok ? "ok" : throttled(r) ? (r.status === 429 ? "429" : "403_throttle") : r.status >= 500 ? "5xx" : String(r.status);
function addTally(n: CallTally) {
  const t = callTally.get(`${n.kind}|${n.result}`) ?? { kind: n.kind, result: n.result, calls: 0, ms: 0, ms_max: 0 };
  t.calls += n.calls;
  t.ms += n.ms;
  t.ms_max = Math.max(t.ms_max, n.ms_max);
  callTally.set(`${n.kind}|${n.result}`, t);
}
const failResult = (e: unknown) => (e instanceof DOMException && e.name === "TimeoutError" ? "timeout" : "network");
const tallyCall = (pathname: string, result: string, ms: number) =>
  addTally({ kind: kindOf(pathname), result, calls: 1, ms, ms_max: ms });
// A SunSynk call that failed for good (after the retries), as one PostHog issue per data
// type and result, sent at most once an hour (SOLAR-336). The full counts are in the tally.
const sunsynkFailed = (pathname: string, result: string, e: unknown) =>
  noteError(`sunsynk_${result}:${kindOf(pathname)}`, e, { hourly: true });

/**
 * Adds the counts since the last save to private.sunsynk_calls in one write (0178). A poll
 * run also passes its shard, run time and plants. A failed write keeps the counts for the
 * next save.
 */
export async function saveCallTally(run?: { shard: number; ms: number; plants: number }): Promise<void> {
  const rows = [...callTally.values()];
  callTally.clear();
  if (!rows.length && !run) return;
  const { error } = await db.rpc("sunsynk_tally", {
    p_rows: rows, p_shard: run?.shard ?? null, p_run_ms: run?.ms ?? 0, p_plants: run?.plants ?? 0,
  });
  if (error) {
    rows.forEach(addTally);
    console.warn("sunsynk_tally:", error.message);
  }
}

/** GET a resource for one account and return body.data. */
export async function apiGet(pathname: string, acc: Account): Promise<any> {
  const doFetch = async (tok: string) => {
    countCall(acc);
    const t0 = Date.now();
    try {
      const res = await fetch(`${baseFor(tok)}${pathname}`, { headers: signedHeaders("GET", pathname, undefined, tok) });
      tallyCall(pathname, resultOf(res), Date.now() - t0);
      return res;
    } catch (e) {
      tallyCall(pathname, failResult(e), Date.now() - t0);
      sunsynkFailed(pathname, failResult(e), e);
      throw e;
    }
  };

  let res = await doFetch(await accessTokenFor(acc));
  if (res.status === 401) res = await doFetch(await accessTokenFor(acc, true));

  for (let attempt = 1; throttled(res) && attempt <= RATE_LIMIT_RETRIES; attempt++) {
    await res.body?.cancel();
    await wait(RATE_LIMIT_BACKOFF_MS * attempt);
    res = await doFetch(await accessTokenFor(acc));
  }
  if (throttled(res)) {
    const e = new Error(`API ${pathname} -> HTTP ${res.status} (rate-limited after ${RATE_LIMIT_RETRIES} retries)`);
    sunsynkFailed(pathname, resultOf(res), e);
    throw e;
  }
  const gatewayErr = res.headers.get("x-ca-error-message");
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = new Error(`API ${pathname} -> HTTP ${res.status} ${gatewayErr ?? body?.msg ?? ""}`);
    sunsynkFailed(pathname, resultOf(res), e);
    throw e;
  }
  return body?.data;
}

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

export type PlantInfo = { id: number; name: string };

/**
 * Walk a paged list endpoint to the end. SunSynk pages `/plants` and `/inverters`
 * (`total`, `pageSize`, `infos[]`); an installer login can see hundreds, and
 * page 1 alone silently dropped the rest (READINESS P4). Stops when a page comes
 * back short, when `total` is reached, or at MAX_PAGES as a guard.
 */
const PAGE_LIMIT = 50;
const MAX_PAGES = 40;
async function apiGetAll(base: string, acc: Account): Promise<any[]> {
  const out: any[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const sep = base.includes("?") ? "&" : "?";
    const data = await apiGet(`${base}${sep}page=${page}&limit=${PAGE_LIMIT}`, acc);
    const list: any[] = (data && (data.infos || data.records)) || [];
    out.push(...list);
    const total = Number(data?.total);
    const pageSize = Number(data?.pageSize) || PAGE_LIMIT;
    if (!list.length || list.length < pageSize) break;
    if (Number.isFinite(total) && out.length >= total) break;
  }
  return out;
}

/** Plants visible to this account — owned or shared to it. */
export async function getPlants(acc: Account): Promise<PlantInfo[]> {
  const list = await apiGetAll("/plants", acc);
  return list.map((p: any) => ({ id: Number(p.id), name: p.name ?? String(p.id) }));
}

// No panel capacity here on purpose: SunSynk's totalPower is the figure from the first
// install and is never revised, so the owner sets it in Settings (0054).
export type PlantDetail = {
  id: number; timezone: string | null;
  lat: number | null; lon: number | null;
};

/** What the API knows about a plant that belongs in plant_config. */
export async function getPlantDetail(acc: Account, plantId: number): Promise<PlantDetail> {
  const d = (await apiGet(`/plant/${plantId}?lan=en`, acc)) ?? {};
  const n = (v: unknown) => (v == null || v === "" || !Number.isFinite(Number(v)) ? null : Number(v));
  return {
    id: plantId,
    timezone: d?.timezone?.code ?? null,      // IANA, e.g. "Africa/Harare", "Europe/London"
    lat: n(d?.lat), lon: n(d?.lon),
  };
}

/** All inverters visible to this account. */
export async function getInverters(acc: Account): Promise<InverterInfo[]> {
  const list = await apiGetAll("/inverters?total=0&status=-1&type=-2", acc);
  return list.map((i: any) => ({
    sn: i.sn,
    alias: i.alias || i.sn,
    plantId: i.plant && (i.plant.id || i.plantId),
    plantName: i.plant && i.plant.name,
    model: i.model || i.equipMode || i.equipModel,
    status: i.status,
    gsn: i.gsn,
    soft: (i.version && i.version.softVer) || i.softVer,
    hmi: i.version && i.version.hmiVer,
    commType: i.commTypeName,
  }));
}

/**
 * The account's inverters as the poller last stored them (private.inverters +
 * private.meta, migration 0031). Same shape as getInverters() so the two are
 * interchangeable; empty until the first live fetch has been committed.
 */
export async function getInvertersCached(acc: Account): Promise<InverterInfo[]> {
  const rows = await rpc<any[]>("inverters_cached", { p_account: acc.id });
  return (rows ?? []).map((r) => ({
    sn: r.sn,
    alias: r.alias ?? r.sn,
    plantId: r.plant_id == null ? undefined : Number(r.plant_id),
    plantName: r.plant_name ?? undefined,
    model: r.model ?? undefined,
    status: r.status ?? undefined,
    gsn: r.gsn ?? undefined,
    soft: r.soft_ver ?? undefined,
    hmi: r.hmi_ver ?? undefined,
    commType: r.comm_type ?? undefined,
    lastReading: r.last_reading ?? null,
    carriedRun: Number(r.carried_run) || 0,
  }));
}

// ---------------------------------------------------------------------------
// Linking
// ---------------------------------------------------------------------------

/**
 * Link a SunSynk login to a dashboard user. Exchanges the password for tokens,
 * stores the refresh token in Vault, records the plants the account can see.
 * Returns the account id and its plants. The password is dropped on return.
 */
/**
 * A plant the plan has no room for links paused (decided 2026-10-27): shown in Account,
 * not polled. The database decides which (0127 trigger), under a per-user lock, so two
 * links at once can't both take the last place. Returns the plants and which are paused.
 */
export async function linkAccount(userId: string, username: string, password: string) {
  const t = await tokenLogin(username, password);
  const acc: Account = {
    id: "", user_id: userId, sunsynk_username: username,
    access_token: t.access_token, access_expires_at: expiresAt(t.expires_in),
  };
  const plants = await getPlants(acc);
  const invs = await getInverters(acc);

  acc.id = await rpc<string>("account_upsert", {
    p_user: userId, p_username: username, p_access: t.access_token, p_expires: acc.access_expires_at,
  });
  await rpc("account_refresh_set", { p_account: acc.id, p_refresh: t.refresh_token });
  const active = new Set((await syncPlants(acc, { plants, invs })).map((p) => p.id));
  await rpc("billing_free_week_start", { p_user: userId, p_sunsynk_username: username });
  const paused = plants.filter((p) => !active.has(p.id)).map((p) => p.id);
  return { accountId: acc.id, plants, paused, reason: paused.length ? "upgrade_needed" : null };
}

/**
 * Record every plant the account can see against its dashboard user, and seed
 * plant_config for any plant that has no row yet. Timezone and lat/lon are
 * SunSynk's own values for the site; panel capacity is not seeded at all, because
 * SunSynk's figure is the one from the first install (0054). Currency is not sent, so the seed stores
 * rand: the app serves South Africa only for now. Never overwrites a
 * config row (the user's edits are theirs) and never removes a plant_users row
 * (unlinking stays a user action). Called at link time and by the poller's
 * hourly refresh, so a plant added at SunSynk later shows up on its own.
 *
 * Plant detail is one call per plant and only ever seeds a missing config row, so
 * it is fetched only for plants that have none (one select, zero SunSynk calls
 * for a plant already seeded).
 */
const MAX_BOOTSTRAP_KICKS = 5;
export async function syncPlants(acc: Account, linked?: { plants: PlantInfo[]; invs: InverterInfo[] }): Promise<PlantInfo[]> {
  const all = linked?.plants ?? await getPlants(acc);
  const invs = linked?.invs;
  // The hourly refresh links a plant SunSynk shows later. The database links it stopped
  // when the plan has no room (0129 trigger); the user sees it in Account and can upgrade.
  // Plant id order, so the same new plants fill the room on every path.
  await rpc("plant_users_upsert", {
    p_user: acc.user_id, p_account: acc.id,
    p_rows: all.slice().sort((a, b) => a.id - b.id).map((p) => ({ plant_id: p.id, plant_name: p.name })),
  });
  // Only plants this user has active go on: a paused plant is not seeded, imported or polled.
  const { data: pausedRows, error: pausedErr } = await db.from("plant_users").select("plant_id")
    .eq("user_id", acc.user_id).eq("paused", true).in("plant_id", all.map((p) => p.id));
  if (pausedErr) throw new Error(`plant_users: ${pausedErr.message}`);
  const paused = new Set((pausedRows ?? []).map((r: any) => Number(r.plant_id)));
  return await seedPlants(acc, all, paused, invs);
}

/**
 * The part of syncPlants after plant_users: store a paused plant's serials, and seed,
 * import and kick the active plants that have no plant_config row yet. A claimed shared
 * plant (SOLAR-310) comes through here too. Returns the active plants.
 */
export async function seedPlants(acc: Account, all: PlantInfo[], paused: Set<number>, invs?: InverterInfo[]): Promise<PlantInfo[]> {
  const plants = all.filter((p) => !paused.has(p.id));
  // A paused plant's inverter serials are stored too, so the paywall can price it.
  // Nothing polls them: plantsToPoll leaves paused plants out.
  if (paused.size && invs) {
    const seed = invs.filter((i) => i.plantId != null && paused.has(Number(i.plantId)));
    if (seed.length) {
      try { await rpc("inverters_seed", { p_rows: seed.map((i) => ({ sn: i.sn, plant_id: i.plantId, account_id: acc.id })) }); }
      catch (e) {
        console.warn(`inverter seed for paused ${[...paused].join(",")}:`, e instanceof Error ? e.message : e);
        noteError("inverter_seed_failed", e, { user: acc.user_id, hourly: true });
      }
    }
  }
  const { data: seeded, error } = await db.from("plant_config").select("plant_id")
    .in("plant_id", plants.map((p) => p.id));
  if (error) throw new Error(`plant_config: ${error.message}`);
  const have = new Set((seeded ?? []).map((r: any) => Number(r.plant_id)));
  const missing = plants.filter((p) => !have.has(p.id));
  const details = await Promise.allSettled(missing.map((p) => getPlantDetail(acc, p.id)));
  const rows = details
    .filter((r): r is PromiseFulfilledResult<PlantDetail> => r.status === "fulfilled")
    .map((r) => ({
      plant_id: r.value.id, timezone: r.value.timezone,
      lat: r.value.lat, lon: r.value.lon,
    }));
  if (rows.length) await rpc("plant_config_seed", { p_rows: rows });
  // Free past its week (0111, SOLAR-241): recover never walks these plants back, so
  // drop the 60-day bookmarks now rather than show "Fetching history" until the trim.
  if (rows.length) {
    const trimmed = await freeTrimmedPlants();
    const cut = rows.map((r) => r.plant_id).filter((id) => trimmed.has(id));
    if (cut.length) {
      const { error } = await db.from("plant_config").update({ backfill_next: null, backfill_until: null, temp_next: null }).in("plant_id", cut);
      if (error) {
        console.warn(`free bookmarks ${cut.join(",")}: ${error.message}`);
        noteError("free_bookmarks_failed", new Error(`free bookmarks ${cut.join(",")}: ${error.message}`), { hourly: true });
      }
    }
  }
  // Plants seeded just now (0044): store their inverter serials so `recover` can
  // ask SunSynk for per-inverter history before the first poll has run, then fire
  // sync-plant-energy and recover for each. Best effort — a failure here leaves
  // the plant on the nightly schedule, which is where it was before 0044.
  if (rows.length) {
    const seededIds = rows.map((r) => r.plant_id);
    const wanted = new Set(seededIds);
    try {
      const seed = (invs ?? await getInverters(acc)).filter((i) => i.plantId != null && wanted.has(Number(i.plantId)));
      if (seed.length) {
        await rpc("inverters_seed", { p_rows: seed.map((i) => ({ sn: i.sn, plant_id: i.plantId, account_id: acc.id })) });
      }
    } catch (e) {
      // recover refuses to walk a plant with no serials, and the first poll stores them.
      console.warn(`inverter seed for ${seededIds.join(",")}:`, e instanceof Error ? e.message : e);
      noteError("inverter_seed_failed", e, { user: acc.user_id, hourly: true });
    }
    // Two edge invocations per plant. An installer login can see hundreds of
    // plants at once; those go to the nightly schedule instead of a burst.
    if (seededIds.length <= MAX_BOOTSTRAP_KICKS) {
      for (const pid of seededIds) {
        try { await rpc("plant_bootstrap_kick", { p_plant: pid }); }
        catch (e) {
          console.warn(`bootstrap kick ${pid}:`, e instanceof Error ? e.message : e);
          noteError("bootstrap_kick_failed", e, { plant: pid, hourly: true });
        }
      }
    } else {
      console.log(`${seededIds.length} plants seeded at once; leaving them to the schedule`);
    }
  }
  return plants;
}

/**
 * One-time bootstrap so a deployment that used to run on env credentials keeps
 * logging without anyone visiting the Connect screen. Needs SUNSYNK_USERNAME,
 * SUNSYNK_PASSWORD and BOOTSTRAP_USER_EMAIL. No-op if that login is already linked.
 */
export async function ensureBootstrapAccount(): Promise<boolean> {
  const username = Deno.env.get("SUNSYNK_USERNAME");
  const password = Deno.env.get("SUNSYNK_PASSWORD");
  const email = Deno.env.get("BOOTSTRAP_USER_EMAIL");
  if (!username || !password || !email) return false;

  const existing = await rpc<any[]>("account_by_username", { p_username: username });
  if (Array.isArray(existing) && existing.length) return false;

  const { data, error } = await db.auth.admin.listUsers({ perPage: 1000 });
  if (error) throw new Error(`listUsers: ${error.message}`);
  const user = data.users.find((u) => u.email?.toLowerCase() === email.toLowerCase());
  if (!user) throw new Error(`bootstrap: no auth user with email ${email}`);

  await linkAccount(user.id, username, password);
  console.log(`bootstrap: linked ${username} to ${email}`);
  return true;
}

/** Every plant that should be worked on, with the account that can read it. */
export type PlantJob = {
  plantId: number; plantName: string | null; timezone: string;
  /** plant_config.batt_positive_means; null until detected or set (0041) */
  battPositiveMeans: string | null;
  /** plant_config.backfill_next / backfill_until (0044): YYYY-MM-DD, null = none pending */
  backfillNext: string | null;
  backfillUntil: string | null;
  backfillTries: number;
  /** plant_config.temp_next (0045): next local day of the inverter-temperature walk; null = not started */
  tempNext: string | null;
  tempTries: number;
  /** plant_config.has_grid (0042): false = off-grid, null = not known yet */
  hasGrid: boolean | null;
  account: Account;
};

export async function plantsToPoll(): Promise<PlantJob[]> {
  // accounts_active orders by linked_at, so index = seniority.
  const accounts = await rpc<Account[]>("accounts_active", {});
  if (!accounts?.length) return [];
  const rank = new Map(accounts.map((a, i) => [a.id, i]));
  const byId = new Map(accounts.map((a) => [a.id, a]));
  const { data, error } = await db
    .from("plant_users").select("plant_id, plant_name, account_id")
    .in("account_id", [...byId.keys()]).eq("paused", false).is("share_gone_at", null);
  if (error) throw new Error(`plant_users: ${error.message}`);
  const { data: cfgRows } = await db.from("plant_config").select("plant_id, timezone, batt_positive_means, backfill_next, backfill_until, backfill_tries, has_grid, temp_next, temp_tries");
  const cfg = new Map((cfgRows ?? []).map((c: any) => [Number(c.plant_id), c]));
  // One job per plant even if several users share it. A plant paused for every user
  // (0110) has no row here, so it is not polled and no data is saved for it. The plant is read through
  // the EARLIEST-linked active account, and that choice is stable from minute to
  // minute — the inverter cache (freshness gate, carry run) is keyed by account,
  // so a flip would throw it away every time. If that account dies (needs_relink)
  // the next-oldest takes over on the following minute.
  const best = new Map<number, { row: any; acc: Account }>();
  for (const r of data ?? []) {
    const pid = Number(r.plant_id);
    if (!r.account_id) continue;
    const acc = byId.get(r.account_id);
    if (!acc) continue;
    const cur = best.get(pid);
    if (!cur || (rank.get(acc.id) ?? 1e9) < (rank.get(cur.acc.id) ?? 1e9)) best.set(pid, { row: r, acc });
  }
  return [...best.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([pid, { row, acc }]) => ({
      plantId: pid,
      plantName: row.plant_name ?? null,
      timezone: String(cfg.get(pid)?.timezone ?? "Africa/Johannesburg"),
      battPositiveMeans: cfg.get(pid)?.batt_positive_means ?? null,
      backfillNext: cfg.get(pid)?.backfill_next ?? null,
      backfillUntil: cfg.get(pid)?.backfill_until ?? null,
      backfillTries: Number(cfg.get(pid)?.backfill_tries ?? 0),
      tempNext: cfg.get(pid)?.temp_next ?? null,
      tempTries: Number(cfg.get(pid)?.temp_tries ?? 0),
      hasGrid: cfg.get(pid)?.has_grid ?? null,
      account: acc,
    }));
}

/**
 * One poll shard's jobs (0100): same plants and account choice as plantsToPoll(),
 * but the shard filter runs in SQL, so a shard reads only its own accounts.
 * account set = only plants read through that account, whatever the shard.
 */
export async function pollJobs(shard: number, shards: number, account?: string): Promise<PlantJob[]> {
  const rows = await rpc<any[]>("poll_jobs", { p_shard: shard, p_shards: shards, p_account: account ?? null });
  const accs = new Map<string, Account>();
  return (rows ?? []).map((r) => {
    const acc = accs.get(r.account_id) ?? {
      id: r.account_id, user_id: r.user_id, sunsynk_username: r.sunsynk_username,
      access_token: r.access_token, access_expires_at: r.access_expires_at,
    };
    accs.set(acc.id, acc); // one object per account, as plantsToPoll() gave
    return {
      plantId: Number(r.plant_id),
      plantName: r.plant_name ?? null,
      timezone: String(r.timezone),
      battPositiveMeans: r.batt_positive_means ?? null,
      backfillNext: r.backfill_next ?? null,
      backfillUntil: r.backfill_until ?? null,
      backfillTries: Number(r.backfill_tries),
      tempNext: r.temp_next ?? null,
      tempTries: Number(r.temp_tries),
      hasGrid: r.has_grid ?? null,
      account: acc,
    };
  });
}

/**
 * Round-robin for the batch functions (recover, sync-plant-energy). Each has a
 * time budget shared across every plant; without this, plants late in the list
 * could starve run after run (READINESS P3). The id of the last plant a run
 * finished is kept in app_config under `key`; the next run starts after it.
 */
/** Plants on Free past their first week (0111): they keep 24 hours, so nothing fetches older days. */
export async function freeTrimmedPlants(): Promise<Set<number>> {
  const ids = await rpc<number[]>("free_trimmed_plants", {});
  return new Set((ids ?? []).map(Number));
}

export async function rotateJobs<T extends { plantId: number }>(jobs: T[], key: string): Promise<T[]> {
  if (jobs.length < 2) return jobs;
  const { data } = await db.from("app_config").select("value").eq("key", key).maybeSingle();
  const last = data ? Number(data.value) : null;
  if (last == null) return jobs;
  const i = jobs.findIndex((j) => j.plantId === last);
  if (i < 0) return jobs; // that plant is gone; start from the top
  return [...jobs.slice(i + 1), ...jobs.slice(0, i + 1)];
}
export async function markCursor(key: string, plantId: number): Promise<void> {
  const { error } = await db.from("app_config")
    .upsert({ key, value: plantId, note: "last plant finished by this batch function; the next run starts after it" }, { onConflict: "key" });
  if (error) {
    console.warn(`cursor ${key}:`, error.message);
    noteError("cursor_failed", new Error(`cursor ${key}: ${error.message}`), { hourly: true });
  }
}

/**
 * The plant the single-site features (alerts) are bound
 * to: pinned in app_config.CALIBRATION_PLANT by the first link (migration 0041).
 * Same rule as public.calibration_plant().
 */
export async function bootstrapPlantId(): Promise<number | null> {
  const v = await rpc<number | null>("calibration_plant", {});
  return v == null ? null : Number(v);
}

// ---------------------------------------------------------------------------
// Shared plants (SOLAR-310, 0172)
// ---------------------------------------------------------------------------

/** The auth user that owns the share login row: one for the share address, made once. */
async function shareUserId(): Promise<string> {
  // Not confirmed: nobody signs in as it, and the welcome and no-plant emails never start.
  const made = await db.auth.admin.createUser({ email: SHARE_USERNAME, email_confirm: false });
  if (made.data?.user) return made.data.user.id;
  for (let page = 1; page <= 50; page++) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw new Error(`listUsers: ${error.message}`);
    const u = data.users.find((x) => x.email?.toLowerCase() === SHARE_USERNAME.toLowerCase());
    if (u) return u.id;
    if (data.users.length < 1000) break;
  }
  throw new Error(`share login: no auth user for the share address (${made.error?.message ?? "create failed"})`);
}

/**
 * The share login, signed in. Signs in with the secret when there is no row yet or the
 * stored one died. Null when the secrets are not set.
 */
export async function shareAccount(): Promise<Account | null> {
  const password = Deno.env.get("SUNSYNK_SHARE_PASSWORD");
  if (!SHARE_USERNAME || !password) return null;
  const row = (await rpc<any[]>("share_account_get", {}))?.[0];
  if (row?.status === "active") return row as Account;
  const t = await tokenLogin(SHARE_USERNAME, password);
  const exp = expiresAt(t.expires_in);
  const userId: string = row?.user_id ?? await shareUserId();
  const id = await rpc<string>("share_account_set", {
    p_user: userId, p_username: SHARE_USERNAME, p_access: t.access_token, p_expires: exp,
  });
  await rpc("account_refresh_set", { p_account: id, p_refresh: t.refresh_token });
  return { id, user_id: userId, sunsynk_username: SHARE_USERNAME, access_token: t.access_token, access_expires_at: exp };
}

/** Hourly in poll: claimed plants that left the share list stop, and come back when shared again. */
export async function shareSync(acc: Account): Promise<unknown> {
  const plants = await getPlants(acc);
  // apiGetAll stops at MAX_PAGES: a full list may be cut short, and the cut plants would read as unshared.
  if (plants.length >= MAX_PAGES * PAGE_LIMIT) throw new Error(`share list at the ${plants.length} plant cap; raise MAX_PAGES`);
  return await rpc("share_sync", { p_account: acc.id, p_plants: plants.map((p) => p.id) });
}

export type ClaimResult =
  | { result: "not_shared" }
  | { result: "taken" | "yours" | "claimed" | "claimed_paused"; plantId: number; plantName: string };

/**
 * Claim a plant shared to the share login: `ref` is its plant id or one of its inverter
 * serials. Checked live against what SunSynk shows the share login.
 */
export async function claimShared(userId: string, ref: string): Promise<ClaimResult> {
  const acc = await shareAccount();
  if (!acc) throw new Error("share login not set up");
  const plants = await getPlants(acc);
  // The login just answered: say so, or a plant claimed between polls shows "Not updating"
  // for its first minutes, timed from the share login's last poll (SOLAR-448).
  await rpc("account_access_set", { p_account: acc.id, p_access: acc.access_token, p_expires: acc.access_expires_at });
  let invs: InverterInfo[] | undefined;
  let plant = /^\d+$/.test(ref) ? plants.find((p) => p.id === Number(ref)) : undefined;
  if (!plant) {
    invs = await getInverters(acc);
    const inv = invs.find((i) => i.sn.toLowerCase() === ref.toLowerCase());
    plant = inv?.plantId != null ? plants.find((p) => p.id === Number(inv.plantId)) : undefined;
  }
  if (!plant) return { result: "not_shared" };
  const result = await rpc<"taken" | "yours" | "claimed" | "claimed_paused">("share_claim", {
    p_user: userId, p_account: acc.id, p_plant: plant.id, p_plant_name: plant.name,
  });
  if (result === "claimed" || result === "claimed_paused") {
    invs ??= await getInverters(acc);
    const mineOnly = invs.filter((i) => Number(i.plantId) === plant.id);
    await seedPlants(acc, [plant], new Set(result === "claimed_paused" ? [plant.id] : []), mineOnly);
  }
  return { result, plantId: plant.id, plantName: plant.name };
}

export { num, pick };
