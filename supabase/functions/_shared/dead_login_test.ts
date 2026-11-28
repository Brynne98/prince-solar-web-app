// SOLAR-701: a login whose sign-in is refused is marked needs_reconnect within the minute, by the
// reader and by plant-jobs; it is never reported as "the brand sent no reading". A failed single
// call on a working login is still only a missing reading.
// deno test -A --node-modules-dir=none _shared/dead_login_test.ts
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { useDb } from "./db.ts";
import { accountFailed, emailOutcome, readAccount } from "./poller.ts";
import { type Account, RelinkNeeded } from "./brands/index.ts";
import { runSync } from "./sidejobs.ts";
import { isListMinute } from "../poll/minutes.mts";

const marks: Record<string, unknown>[] = [];
useDb({
  rpc: async (fn: string, args: Record<string, unknown>) => {
    if (fn === "account_mark") marks.push(args);
    if (fn === "account_refresh_get") return "rt-old";
    if (fn === "sync_logins") return [{ id: LOGIN, user_id: "u1", username: "owner@example.test", brand: "sunsynk", access_token: "at-old", access_expires_at: 1 }];
    return [];
  },
  configuredPlants: async () => [],
  clearBookmarks: async () => {},
} as any);

const LOGIN = "11111111-2222-3333-4444-555555555555";
const realFetch = globalThis.fetch;
// SunSynk answers the refresh normally and refuses it (no access_token in data); input may 404
function brand(inputStatus = 200, otherStatus = 200) {
  globalThis.fetch = (async (u: string | URL | Request) => {
    const url = String(u);
    if (url.endsWith("/oauth/token")) return new Response(JSON.stringify({ code: 102, msg: "refresh token invalid", data: null }));
    if (url.includes("/realtime/input")) {
      return new Response(JSON.stringify({ code: 0, data: { pvIV: [{ time: "2026-11-28 10:00:00" }] } }), { status: inputStatus });
    }
    return new Response(JSON.stringify({ code: 0, data: {} }), { status: otherStatus });
  }) as typeof fetch;
}
const acc = (expired: boolean): Account =>
  ({ id: LOGIN, user_id: "u1", username: "owner@example.test", brand: "sunsynk", access_token: "at-old",
     access_expires_at: expired ? 1 : Date.now() + 3_600_000 }) as Account;
const inv = { sn: "2303222237", plantId: 495944, status: 1, lastReading: null } as any;
const jobs = [{ plantId: 495944, account: acc(true), timezone: "Africa/Johannesburg", version: 1, battPositiveMeans: null, hasGrid: false }] as any;
const ts = Math.floor(Date.now() / 60000) * 60;

Deno.test({ name: "a refused refresh reaches the reader and marks the login needs_reconnect", sanitizeOps: false, sanitizeResources: false, fn: async () => { try {
  marks.length = 0;
  brand();
  const a = acc(true);
  await assertRejects(() => readAccount(a, jobs, ts, { cached: [inv] }), RelinkNeeded);
  // what poll/index.ts does with it
  const r = await readAccount(a, jobs, ts, { cached: [inv] }).then((x) => x.result).catch((e) => accountFailed(a, jobs, e));
  assertEquals(marks.at(-1)?.p_status, "needs_reconnect");
  assertEquals(emailOutcome(r), null);   // not mailed as "the brand sent no reading"
  } finally { globalThis.fetch = realFetch; }
} });

Deno.test({ name: "the input answers, then another endpoint's 401 meets a refused refresh: still marked", sanitizeOps: false, sanitizeResources: false, fn: async () => { try {
  marks.length = 0;
  brand(200, 401);
  const a = acc(false);
  const r = await readAccount(a, jobs, ts, { cached: [inv] }).then((x) => x.result).catch((e) => accountFailed(a, jobs, e));
  assertEquals(marks.at(-1)?.p_status, "needs_reconnect");
  assertEquals(emailOutcome(r), null);
  } finally { globalThis.fetch = realFetch; }
} });

Deno.test({ name: "one failed call on a working login is still only a missing reading", sanitizeOps: false, sanitizeResources: false, fn: async () => { try {
  marks.length = 0;
  brand(404);
  const read = await readAccount(acc(false), jobs, ts, { cached: [inv] });
  assertEquals(read.row, null);
  assertEquals(read.result.noData, [inv.sn]);
  assertEquals(marks.length, 0);
  } finally { globalThis.fetch = realFetch; }
} });

Deno.test({ name: "plant-jobs marks a login whose refresh is refused", sanitizeOps: false, sanitizeResources: false, fn: async () => { try {
  marks.length = 0;
  brand();
  let t = ts;
  while (!isListMinute(LOGIN, t)) t += 60;
  const out = await runSync(t);
  assert(out.failed >= 1);
  assertEquals(marks.at(-1)?.p_account, LOGIN);
  assertEquals(marks.at(-1)?.p_status, "needs_reconnect");
  } finally { globalThis.fetch = realFetch; }
} });
