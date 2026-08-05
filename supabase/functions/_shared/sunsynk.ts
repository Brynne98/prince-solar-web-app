// SunSynk Connect auth + fetch, ported from server.js.
//
// Two changes vs the monolith, both forced by Edge Functions being stateless:
//   * the token moves from an in-memory tokenCache to a Postgres row
//   * that row lives in the `private` schema, which PostgREST does not expose, so it
//     is reached through the SECURITY DEFINER accessors in migration 0002 rather
//     than a .from() call. The anon key in the public frontend bundle has no route
//     to it — not the table, not the schema, not these functions.
//
// The login crypto is unchanged: RSA PKCS#1 v1.5, which Web Crypto cannot do at all
// but node:crypto can. Verified working on supabase-edge-runtime-1.74.0 (Deno 2.1.4).
import { createClient } from "jsr:@supabase/supabase-js@2";
import { Buffer } from "node:buffer";
import { constants, createHash, publicEncrypt } from "node:crypto";
import { type InverterInfo, num, pick, type RawBundle, realtimePaths } from "./extract.ts";

const API_BASE = Deno.env.get("API_BASE") ?? "https://api.sunsynk.net";
const SOURCE = "sunsynk";
const USERNAME = Deno.env.get("SUNSYNK_USERNAME")!;
const PASSWORD = Deno.env.get("SUNSYNK_PASSWORD")!;

export const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const md5Hex = (v: string) => createHash("md5").update(v, "utf8").digest("hex");
const nonce = () => Date.now();

function rsaEncryptPkcs1(rawKey: string, plaintext: string): string {
  const pem = `-----BEGIN PUBLIC KEY-----\n${rawKey.replace(/(.{64})/g, "$1\n")}\n-----END PUBLIC KEY-----`;
  const ct = publicEncrypt({ key: pem, padding: constants.RSA_PKCS1_PADDING }, Buffer.from(plaintext, "utf8"));
  return ct.toString("base64");
}

async function fetchPublicKey(): Promise<string> {
  const n = nonce();
  const sign = md5Hex(`nonce=${n}&source=${SOURCE}POWER_VIEW`);
  const res = await fetch(
    `${API_BASE}/anonymous/publicKey?nonce=${n}&source=${SOURCE}&sign=${sign}`,
    { headers: { "Content-Type": "application/json", Accept: "application/json" } },
  );
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.success || !body.data) throw new Error(`login key: ${body?.msg ?? res.status}`);
  return body.data;
}

async function login(): Promise<string> {
  const rawKey = await fetchPublicKey();
  const encryptedPassword = rsaEncryptPkcs1(rawKey, PASSWORD);
  const n = nonce();
  const sign = md5Hex(`nonce=${n}&source=${SOURCE}${rawKey.slice(0, 10)}`);
  const res = await fetch(`${API_BASE}/oauth/token/new`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({
      username: USERNAME, password: encryptedPassword, grant_type: "password",
      client_id: "csp-web", source: SOURCE, nonce: n, sign,
    }),
  });
  const body = await res.json().catch(() => ({}));
  const data = body?.data;
  if (!res.ok || !body.success || !data?.access_token) {
    throw new Error(`login failed: ${body?.msg ?? res.status}`);
  }
  const { error } = await db.rpc("auth_token_set", {
    p_access: data.access_token,
    p_refresh: data.refresh_token ?? null,
    p_expires: Date.now() + (Number(data.expires_in ?? 3600) - 60) * 1000,
  });
  if (error) throw new Error(`persisting token: ${error.message}`);
  return data.access_token;
}

async function getToken(): Promise<string> {
  const { data, error } = await db.rpc("auth_token_get");
  if (error) throw new Error(`reading token: ${error.message}`);
  const row = Array.isArray(data) ? data[0] : data;
  if (row?.access_token && Date.now() < Number(row.expires_at)) return row.access_token;
  return login();
}

/**
 * GET a SunSynk endpoint and return `body.data` — the same unwrapping server.js does,
 * so extractReading() sees the shape it expects.
 *
 * NOTE: the monolith keeps an in-memory cooldown after a 429/403 and escalates the
 * backoff across polls. Edge Functions are stateless, so a 429 here simply fails this
 * tick; the next cron minute retries. Losing one minute is acceptable — gap recovery
 * backfills it from the cloud later.
 */
export async function apiGet(pathname: string): Promise<any> {
  let token = await getToken();
  const doFetch = (t: string) =>
    fetch(`${API_BASE}${pathname}`, {
      headers: { Authorization: `Bearer ${t}`, Accept: "application/json" },
    });

  let res = await doFetch(token);
  if (res.status === 401) {
    await db.rpc("auth_token_expire");
    token = await login();
    res = await doFetch(token);
  }
  if (res.status === 429 || res.status === 403) {
    throw new Error(`API ${pathname} -> HTTP ${res.status} (rate-limited)`);
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`API ${pathname} -> HTTP ${res.status} ${body?.msg ?? ""}`);
  return body?.data;
}

/** All inverters on the account (server.js getInverters). */
export async function getInverters(): Promise<InverterInfo[]> {
  const data = await apiGet("/api/v1/inverters?page=1&limit=20&total=0&status=-1&type=-2");
  const list = (data && (data.infos || data.records)) || [];
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

/** All 5 raw payloads for one inverter; failed endpoints come back null. */
export async function fetchInverterRaw(sn: string): Promise<RawBundle> {
  const paths = realtimePaths(sn);
  const keys = Object.keys(paths) as (keyof RawBundle)[];
  const settled = await Promise.allSettled(keys.map((k) => apiGet(paths[k])));
  const raw = {} as RawBundle;
  keys.forEach((k, i) => {
    raw[k] = settled[i].status === "fulfilled" ? (settled[i] as PromiseFulfilledResult<any>).value : null;
  });
  return raw;
}

export { num, pick };
