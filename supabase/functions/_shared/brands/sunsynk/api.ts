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
//
// SOLAR-681: this file is the SunSynk adapter's client half: signing, tokens, calls, the
// plant and inverter lists. Callers outside brands/ go through brands/index.ts (R15).
import { createHash, createHmac } from "node:crypto";
import { type InverterInfo, num, pick } from "./extract.ts";
import { noteError } from "../../errors.ts";
import { slot } from "../../limit.mts";
import { fakeSunsynk, MOCK_PLANT_OFFSET } from "../../gate.ts";
import { mockFetch } from "../../mock-fetch.mts";
import { rpc } from "../../db.ts";
import { type Account, LoginRejected, RelinkNeeded, SignInFailed, type VendorErrorKind, VendorError, type VendorPlant,
  type VendorPlantDetail, type VendorPlantId, vendorPlantId } from "../types.ts";
export type { Account };
export { LoginRejected, RelinkNeeded, SignInFailed };

const API_BASE = Deno.env.get("SUNSYNK_API_BASE") ?? "https://openapi.sunsynk.net";
// Fake logins (name@mock, SOLAR-270) go to the mock: locally the mock server is API_BASE
// already; in production the mock-sunsynk function, which only testers can link
// (link-sunsynk). Its tokens are "at:<login>" and "rt:<login>", unlike any SunSynk token.
const MOCK_BASE = Deno.env.get("SUNSYNK_API_BASE") ?? `${Deno.env.get("SUPABASE_URL")}/functions/v1/mock-sunsynk`;
const baseFor = (loginOrToken: string) => (loginOrToken.endsWith("@mock") ? MOCK_BASE : API_BASE);
const isFake = (loginOrToken: string) => fakeSunsynk(loginOrToken, API_BASE, MOCK_BASE);
// A fake login in production is answered in this function, not over the network (SOLAR-637).
const sunsynkFetch = (who: string, url: string, init: RequestInit) =>
  isFake(who) ? mockFetch(MOCK_BASE, MOCK_PLANT_OFFSET, url, init) : fetch(url, init);
const APP_KEY = Deno.env.get("SUNSYNK_APP_KEY") ?? "";
const APP_SECRET = Deno.env.get("SUNSYNK_APP_SECRET") ?? "";
const CLIENT_ID = "openapi";
// Refresh the access token this many seconds before SunSynk says it expires.
const EXPIRY_MARGIN_S = 300;

if (!APP_KEY || !APP_SECRET) {
  console.warn("SUNSYNK_APP_KEY / SUNSYNK_APP_SECRET not set — every request will fail");
}

export type TokenSet = { access_token: string; refresh_token: string; expires_in: number };

/**
 * The company login owners share their plant to, as Visitor (SOLAR-310). One stored login
 * reads every shared plant; a plant is polled only once an owner has claimed it.
 */
export const SHARE_USERNAME = (Deno.env.get("SUNSYNK_SHARE_USERNAME") ?? "").trim();
export const isShareAccount = (acc: Pick<Account, "username">) =>
  !!SHARE_USERNAME && acc.username.toLowerCase() === SHARE_USERNAME.toLowerCase();

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

// SunSynk's gateway gives up at about 10 s with a 504. A call still open at 15 s has hung,
// and would hold its whole poll shard until pg_net's 55 s cut (Review K item 2, SOLAR-422).
const API_TIMEOUT_MS = 15_000;

// ---------------------------------------------------------------------------
// Token endpoints
// ---------------------------------------------------------------------------

async function postToken(payload: Record<string, string>): Promise<any> {
  const body = JSON.stringify(payload);
  const t0 = Date.now();
  const who = payload.username ?? payload.refresh_token ?? "";
  let res: Response;
  try {
    res = await sunsynkFetch(who, `${baseFor(who)}/oauth/token`, {
      method: "POST",
      headers: signedHeaders("POST", "/oauth/token", body),
      body,
      signal: AbortSignal.timeout(API_TIMEOUT_MS),
    });
  } catch (e) {
    tallyCall(who, "/oauth/token", failResult(e), Date.now() - t0);
    sunsynkFailed(who, "/oauth/token", failResult(e), e);
    throw e;
  }
  tallyCall(who, "/oauth/token", resultOf(res), Date.now() - t0);
  const gatewayErr = res.headers.get("x-ca-error-message");
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = new Error(`token endpoint HTTP ${res.status}: ${gatewayErr ?? json?.msg ?? ""}`);
    sunsynkFailed(who, "/oauth/token", resultOf(res), e);
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

export const expiresAt = (expiresIn: number) => Date.now() + Math.max(60, expiresIn - EXPIRY_MARGIN_S) * 1000;

// ---------------------------------------------------------------------------
// Per-account token management
// ---------------------------------------------------------------------------

// One sign-in renewal per login at a time: a plant's inverters are read in parallel, and
// each used to renew on its own when the token was stale or a 401 came back (Review K item 7).
const renewing = new Map<string, Promise<string>>();

/** A valid access token for this account, refreshing if needed. Throws RelinkNeeded. */
async function accessTokenFor(acc: Account, force = false): Promise<string> {
  if (!force && acc.access_token && acc.access_expires_at && Date.now() < Number(acc.access_expires_at)) {
    return acc.access_token;
  }
  const live = renewing.get(acc.id);
  if (live) return live;
  const p = renewToken(acc).finally(() => renewing.delete(acc.id));
  renewing.set(acc.id, p);
  return p;
}

async function renewToken(acc: Account): Promise<string> {
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
/** Calls per account that stayed rate-limited after the retries: the history queue backs off on them (0246). */
export const throttledCounts = new Map<string, number>();
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
const httpKind = (status: number): VendorErrorKind => (status >= 500 ? "vendor_down" : status === 401 ? "auth" : "refused");
const failResult = (e: unknown) => (e instanceof DOMException && e.name === "TimeoutError" ? "timeout" : "network");
// Fake SunSynk calls (SOLAR-477) are left out: `who` is the login or token used. Calls on
// the company login are kept apart ("share:…"): its rate limit is shared by every plant on
// it, so its 429s must show on their own (SOLAR-649).
const tallyCall = (who: string, pathname: string, result: string, ms: number, share = false) =>
  isFake(who) || addTally({ kind: (share ? "share:" : "") + kindOf(pathname), result, calls: 1, ms, ms_max: ms });
// A SunSynk call that failed for good (after the retries), as one PostHog issue per data
// type and result, sent at most once an hour (SOLAR-336). The full counts are in the tally.
// A failed fake call goes to the function log only (SOLAR-637).
const sunsynkFailed = (who: string, pathname: string, result: string, e: unknown) =>
  isFake(who)
    ? console.warn(`fake sunsynk ${result}:${kindOf(pathname)}: ${e instanceof Error ? e.message : e}`)
    : noteError(`sunsynk_${result}:${kindOf(pathname)}`, e, { hourly: true });

/**
 * Adds the counts since the last save to private.sunsynk_calls in one write (0178). A poll
 * run also passes its shard, run time and plants. A failed write keeps the counts for the
 * next save.
 */
export async function saveCallTally(run?: { shard: number; ms: number; plants: number }): Promise<void> {
  const rows = [...callTally.values()];
  callTally.clear();
  if (!rows.length && !run) return;
  try {
    await rpc("sunsynk_tally", {
      p_rows: rows, p_shard: run?.shard ?? null, p_run_ms: run?.ms ?? 0, p_plants: run?.plants ?? 0,
    });
  } catch (e) {
    rows.forEach(addTally);
    console.warn(e instanceof Error ? e.message : e);
  }
}

// At most this many SunSynk requests in flight per login in one isolate: a login's
// inverters were all read at once, so a company login with many plants hit its rate limit
// in one burst (SOLAR-649).
// A call that waited this long for a place gives up, so a shard still saves what it read
// before pg_net's 55 s cut ends it. The limit counts requests started; a reply's body is
// read after its place is freed.
const MAX_IN_FLIGHT = 10;
const MAX_WAIT_MS = 15_000;

// Poller v3 (SOLAR-656): a cap on calls in flight across every login in this isolate, set by
// the host that reads many logins at once (a lane sizes it from calls/s x p99 latency).
// Infinity = no cap (today's poller). `onCall` hears every call's time and result.
let fleetCap = Infinity;
export const setFleetCap = (n: number) => { fleetCap = Math.max(1, n); };
let onCall: ((ms: number, result: string) => void) | null = null;
export const watchCalls = (f: typeof onCall) => { onCall = f; };

// A 429 makes every call of that login wait out the backoff, not only the one that got it:
// the rate limit is per login (2026-11-10).
const backoffUntil = new Map<string, number>();

/** GET a resource for one account and return body.data. */
export async function apiGet(pathname: string, acc: Account): Promise<any> {
  const share = isShareAccount(acc);
  // the token is read once the call has its place: one renewed while it waited is used
  const doFetch = async (force = false): Promise<Response> => {
    for (let until; (until = backoffUntil.get(acc.id) ?? 0) > Date.now();) await wait(until - Date.now());
    acc.signal?.throwIfAborted();
    const done = await slot(acc.id, MAX_IN_FLIGHT, MAX_WAIT_MS);
    const fleetDone = Number.isFinite(fleetCap)
      ? await slot("*fleet", fleetCap, MAX_WAIT_MS).catch((e) => {
        done();
        throw new Error(`fleet_cap: ${e instanceof Error ? e.message : e}`);   // ours, not SunSynk's
      })
      : () => {};
    // a 429 on this login while the call waited for its place, or the read was dropped
    if ((backoffUntil.get(acc.id) ?? 0) > Date.now() || acc.signal?.aborted) {
      fleetDone();
      done();
      return doFetch(force);
    }
    try {
      const tok = await accessTokenFor(acc, force);
      countCall(acc);
      const t0 = Date.now();
      try {
        const res = await sunsynkFetch(tok, `${baseFor(tok)}${pathname}`, {
          headers: signedHeaders("GET", pathname, undefined, tok),
          signal: acc.signal ? AbortSignal.any([AbortSignal.timeout(API_TIMEOUT_MS), acc.signal]) : AbortSignal.timeout(API_TIMEOUT_MS),
        });
        tallyCall(tok, pathname, resultOf(res), Date.now() - t0, share);
        onCall?.(Date.now() - t0, resultOf(res));
        return res;
      } catch (e) {
        if (acc.signal?.aborted) throw e;   // dropped by us: not SunSynk's failure
        tallyCall(tok, pathname, failResult(e), Date.now() - t0, share);
        onCall?.(Date.now() - t0, failResult(e));
        sunsynkFailed(tok, pathname, failResult(e), e);
        throw new VendorError("vendor_down", `API ${pathname} -> ${failResult(e)}: ${e instanceof Error ? e.message : e}`);
      }
    } finally {
      fleetDone();
      done();
    }
  };

  let res = await doFetch();
  if (res.status === 401) res = await doFetch(true);

  for (let attempt = 1; throttled(res) && attempt <= RATE_LIMIT_RETRIES; attempt++) {
    await res.body?.cancel();
    backoffUntil.set(acc.id, Math.max(backoffUntil.get(acc.id) ?? 0, Date.now() + RATE_LIMIT_BACKOFF_MS * attempt));
    await wait(RATE_LIMIT_BACKOFF_MS * attempt);
    res = await doFetch();
  }
  if (throttled(res)) {
    throttledCounts.set(acc.id, (throttledCounts.get(acc.id) ?? 0) + 1);
    const e = new VendorError("rate", `API ${pathname} -> HTTP ${res.status} (rate-limited after ${RATE_LIMIT_RETRIES} retries)`);
    sunsynkFailed(acc.username, pathname, resultOf(res), e);
    throw e;
  }
  const gatewayErr = res.headers.get("x-ca-error-message");
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = new VendorError(httpKind(res.status), `API ${pathname} -> HTTP ${res.status} ${gatewayErr ?? body?.msg ?? ""}`);
    sunsynkFailed(acc.username, pathname, resultOf(res), e);
    throw e;
  }
  return body?.data;
}

/**
 * GET on SunSynk's own web host, which takes our openapi token as a plain Bearer, no
 * signature (tested 2026-11-20, API.md, SOLAR-612). Unofficial: SunSynk may block it,
 * so every caller keeps an official fallback, and failures are only tallied (kind
 * "web:…"), not reported. Errors come back as HTTP 200 with code ≠ 0.
 */
const WEB_BASE = "https://api.sunsynk.net/api/v1";
const WEB_TIMEOUT_MS = 20_000;
export async function webGet(pathname: string, acc: Account): Promise<any> {
  const tok = await accessTokenFor(acc);
  if (isFake(tok)) throw new Error("web host: not for fake logins");
  countCall(acc);
  const share = isShareAccount(acc);
  const kind = `web:${pathname}`;
  const done = await slot(acc.id, MAX_IN_FLIGHT, MAX_WAIT_MS);
  const t0 = Date.now();
  let res: Response;
  try {
    res = await fetch(`${WEB_BASE}${pathname}`, {
      headers: { Accept: "application/json", Authorization: `Bearer ${tok}` },
      signal: AbortSignal.timeout(WEB_TIMEOUT_MS),
    });
  } catch (e) {
    tallyCall(tok, kind, failResult(e), Date.now() - t0, share);
    throw e;
  } finally {
    done();
  }
  const body = await res.json().catch(() => ({}));
  const ok = res.ok && body?.code === 0;
  tallyCall(tok, kind, ok ? "ok" : res.ok ? `code_${body?.code}` : resultOf(res), Date.now() - t0, share);
  if (!ok) throw new Error(`web ${pathname} -> HTTP ${res.status} code ${body?.code} ${body?.msg ?? ""}`);
  return body.data;
}

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------


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
export async function getPlants(acc: Account): Promise<VendorPlant[]> {
  const list = await apiGetAll("/plants", acc);
  // apiGetAll stops at MAX_PAGES: a list that long may be cut short, and a cut plant would read as gone (R9)
  if (list.length >= MAX_PAGES * PAGE_LIMIT) throw new Error(`plant list at the ${list.length} plant cap; raise MAX_PAGES`);
  return list.map((p: any) => ({ vendorId: vendorPlantId(p.id), name: p.name ?? String(p.id) }));
}

// No panel capacity here on purpose: SunSynk's totalPower is the figure from the first
// install and is never revised, so the owner sets it in Settings (0054).
/** What the API knows about a plant that belongs in plant_config. */
export async function getPlantDetail(acc: Account, id: VendorPlantId): Promise<VendorPlantDetail> {
  const d = (await apiGet(`/plant/${id}?lan=en`, acc)) ?? {};
  const n = (v: unknown) => (v == null || v === "" || !Number.isFinite(Number(v)) ? null : Number(v));
  return {
    vendorId: id,
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
    vendorPlantId: i.plant && (i.plant.id || i.plantId) ? vendorPlantId(i.plant.id || i.plantId) : undefined,
    plantName: i.plant && i.plant.name,
    model: i.model || i.equipMode || i.equipModel,
    status: i.status,
    gsn: i.gsn,
    soft: (i.version && i.version.softVer) || i.softVer,
    hmi: i.version && i.version.hmiVer,
    commType: i.commTypeName,
  }));
}

export { num, pick };
