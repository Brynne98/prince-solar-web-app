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
import { createClient } from "jsr:@supabase/supabase-js@2";
import { createHash, createHmac } from "node:crypto";
import { type InverterInfo, num, pick } from "./extract.ts";

const API_BASE = Deno.env.get("SUNSYNK_API_BASE") ?? "https://openapi.sunsynk.net";
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

export type Account = {
  id: string;
  user_id: string;
  sunsynk_username: string;
  access_token: string | null;
  access_expires_at: number | null;
};

export type TokenSet = { access_token: string; refresh_token: string; expires_in: number };

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
  const res = await fetch(`${API_BASE}/oauth/token`, {
    method: "POST",
    headers: signedHeaders("POST", "/oauth/token", body),
    body,
  });
  const gatewayErr = res.headers.get("x-ca-error-message");
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`token endpoint HTTP ${res.status}: ${gatewayErr ?? json?.msg ?? ""}`);
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
    throw new Error(`login rejected: ${json?.msg ?? "no token in response"}`);
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

  const t = await tokenRefresh(refresh);
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

/** GET a resource for one account and return body.data. */
export async function apiGet(pathname: string, acc: Account): Promise<any> {
  const doFetch = async (tok: string) => {
    countCall(acc);
    return fetch(`${API_BASE}${pathname}`, { headers: signedHeaders("GET", pathname, undefined, tok) });
  };

  let res = await doFetch(await accessTokenFor(acc));
  if (res.status === 401) res = await doFetch(await accessTokenFor(acc, true));

  // The gateway also answers 403 for "this app key may not call that path", which
  // no amount of waiting fixes; only treat a 403 as throttling when its message
  // says so. (Survey 2026-09-05: /plant/{id}/realtime is a plain 403 on this key.)
  const throttled = (r: Response) =>
    r.status === 429 ||
    (r.status === 403 && /throttl|quota|limit/i.test(r.headers.get("x-ca-error-message") ?? ""));
  for (let attempt = 1; throttled(res) && attempt <= RATE_LIMIT_RETRIES; attempt++) {
    await res.body?.cancel();
    await wait(RATE_LIMIT_BACKOFF_MS * attempt);
    res = await doFetch(await accessTokenFor(acc));
  }
  if (throttled(res)) {
    throw new Error(`API ${pathname} -> HTTP ${res.status} (rate-limited after ${RATE_LIMIT_RETRIES} retries)`);
  }
  const gatewayErr = res.headers.get("x-ca-error-message");
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`API ${pathname} -> HTTP ${res.status} ${gatewayErr ?? body?.msg ?? ""}`);
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

export type PlantDetail = {
  id: number; timezone: string | null; currency: string | null;
  lat: number | null; lon: number | null; systemKwp: number | null;
};

/** What the API knows about a plant that belongs in plant_config. */
export async function getPlantDetail(acc: Account, plantId: number): Promise<PlantDetail> {
  const d = (await apiGet(`/plant/${plantId}?lan=en`, acc)) ?? {};
  const n = (v: unknown) => (v == null || v === "" || !Number.isFinite(Number(v)) ? null : Number(v));
  return {
    id: plantId,
    timezone: d?.timezone?.code ?? null,      // IANA, e.g. "Africa/Harare", "Europe/London"
    currency: d?.currency?.code ?? null,      // ISO 4217, e.g. "ZAR", "GBP"
    lat: n(d?.lat), lon: n(d?.lon),
    systemKwp: n(d?.totalPower),
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
export async function linkAccount(userId: string, username: string, password: string) {
  const t = await tokenLogin(username, password);
  const accountId = await rpc<string>("account_upsert", {
    p_user: userId, p_username: username, p_access: t.access_token, p_expires: expiresAt(t.expires_in),
  });
  await rpc("account_refresh_set", { p_account: accountId, p_refresh: t.refresh_token });

  const acc: Account = {
    id: accountId, user_id: userId, sunsynk_username: username,
    access_token: t.access_token, access_expires_at: expiresAt(t.expires_in),
  };
  const plants = await syncPlants(acc);
  return { accountId, plants };
}

/**
 * Record every plant the account can see against its dashboard user, and seed
 * plant_config for any plant that has no row yet. Timezone and currency are
 * SunSynk's own values for the site; lat/lon/kWp likewise. Never overwrites a
 * config row (the user's edits are theirs) and never removes a plant_users row
 * (unlinking stays a user action). Called at link time and by the poller's
 * hourly refresh, so a plant added at SunSynk later shows up on its own.
 *
 * Plant detail is one call per plant and only ever seeds a missing config row, so
 * it is fetched only for plants that have none (one select, zero SunSynk calls
 * for a plant already seeded).
 */
const MAX_BOOTSTRAP_KICKS = 5;
export async function syncPlants(acc: Account): Promise<PlantInfo[]> {
  const plants = await getPlants(acc);
  await rpc("plant_users_upsert", {
    p_user: acc.user_id, p_account: acc.id,
    p_rows: plants.map((p) => ({ plant_id: p.id, plant_name: p.name })),
  });
  const { data: seeded, error } = await db.from("plant_config").select("plant_id")
    .in("plant_id", plants.map((p) => p.id));
  if (error) throw new Error(`plant_config: ${error.message}`);
  const have = new Set((seeded ?? []).map((r: any) => Number(r.plant_id)));
  const missing = plants.filter((p) => !have.has(p.id));
  const details = await Promise.allSettled(missing.map((p) => getPlantDetail(acc, p.id)));
  const rows = details
    .filter((r): r is PromiseFulfilledResult<PlantDetail> => r.status === "fulfilled")
    .map((r) => ({
      plant_id: r.value.id, timezone: r.value.timezone, currency: r.value.currency,
      lat: r.value.lat, lon: r.value.lon, system_kwp: r.value.systemKwp,
    }));
  if (rows.length) await rpc("plant_config_seed", { p_rows: rows });
  // Plants seeded just now (0044): store their inverter serials so `recover` can
  // ask SunSynk for per-inverter history before the first poll has run, then fire
  // sync-plant-energy and recover for each. Best effort — a failure here leaves
  // the plant on the nightly schedule, which is where it was before 0044.
  if (rows.length) {
    const seededIds = rows.map((r) => r.plant_id);
    const wanted = new Set(seededIds);
    try {
      const invs = (await getInverters(acc)).filter((i) => i.plantId != null && wanted.has(Number(i.plantId)));
      if (invs.length) {
        await rpc("inverters_seed", { p_rows: invs.map((i) => ({ sn: i.sn, plant_id: i.plantId, account_id: acc.id })) });
      }
    } catch (e) {
      // recover refuses to walk a plant with no serials, and the first poll stores them.
      console.warn(`inverter seed for ${seededIds.join(",")}:`, e instanceof Error ? e.message : e);
    }
    // Two edge invocations per plant. An installer login can see hundreds of
    // plants at once; those go to the nightly schedule instead of a burst.
    if (seededIds.length <= MAX_BOOTSTRAP_KICKS) {
      for (const pid of seededIds) {
        try { await rpc("plant_bootstrap_kick", { p_plant: pid }); }
        catch (e) { console.warn(`bootstrap kick ${pid}:`, e instanceof Error ? e.message : e); }
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
    .in("account_id", [...byId.keys()]);
  if (error) throw new Error(`plant_users: ${error.message}`);
  const { data: cfgRows } = await db.from("plant_config").select("plant_id, timezone, batt_positive_means, backfill_next, backfill_until, backfill_tries, has_grid, temp_next, temp_tries");
  const cfg = new Map((cfgRows ?? []).map((c: any) => [Number(c.plant_id), c]));
  // One job per plant even if several users share it. The plant is read through
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
 * Round-robin for the batch functions (recover, sync-plant-energy). Each has a
 * time budget shared across every plant; without this, plants late in the list
 * could starve run after run (READINESS P3). The id of the last plant a run
 * finished is kept in app_config under `key`; the next run starts after it.
 */
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
  if (error) console.warn(`cursor ${key}:`, error.message);
}

/**
 * The plant the single-site features (forecast calibration, phone alerts) are bound
 * to: pinned in app_config.CALIBRATION_PLANT by the first link (migration 0041).
 * Same rule as public.calibration_plant().
 */
export async function bootstrapPlantId(): Promise<number | null> {
  const v = await rpc<number | null>("calibration_plant", {});
  return v == null ? null : Number(v);
}

export { num, pick };
