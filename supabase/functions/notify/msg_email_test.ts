// SUPABASE_URL=http://x SUPABASE_SERVICE_ROLE_KEY=x deno test -A --node-modules-dir=none notify/msg_email_test.ts
// (SOLAR-645 step 4): alert emails from the message outbox: take, build, one Resend call per
// row under ms-<id>, and what each Resend answer reports back to msg_email_done.
import { assertEquals } from "jsr:@std/assert@1";
import { type MsgEmail, msgEmailPass, type MsgResult } from "./index.ts";
import type { Email } from "../_shared/email.ts";

const row = (id: number, over: Partial<MsgEmail> = {}): MsgEmail => ({
  id, claim: "c-1", tries: 1, event_id: 100 + id, user_id: "u-1", to_email: `o${id}@x.test`, plant_id: 7,
  plant_name: "Home", tz: "Africa/Johannesburg", kind: "grid_down", key: `k${id}`, data: { since: 1_700_000_000 }, ...over,
});
const mail: Email = { subject: "s", html: "<p>h</p>", text: "t" } as Email;
// The pace between calls is a timer that outlives a test.
const loose = { sanitizeResources: false, sanitizeOps: false };
type Ans = { status: number; error?: string; retryAfter?: string | null };

/** One take of `rows`, then an empty one; Resend answers from `answers` by row id. */
function fake(rows: MsgEmail[], answers: Record<number, Ans> = {}, make = (_r: unknown) => Promise.resolve<Email | null>(mail)) {
  const done: MsgResult[][] = [], keys: string[] = [], to: string[] = [];
  let takes = 0;
  const call = <T>(fn: string, args?: Record<string, unknown>): Promise<T> => {
    if (fn === "msg_email_take") return Promise.resolve((takes++ ? [] : rows) as T);
    if (fn === "msg_email_done") { done.push(args!.p_results as MsgResult[]); return Promise.resolve(null as T); }
    throw new Error(fn);
  };
  const post = (_url: string, body: any, key: string) => {
    keys.push(key); to.push(body.to[0]);
    return Promise.resolve(answers[Number(key.slice(3))] ?? { status: 200 });
  };
  return { done, keys, to,
           run: (until = Date.now() + 20_000, deadline = until) => msgEmailPass(until, deadline, call, post, make as any) };
}

Deno.test("2xx: sent, one call per row under ms-<id>, to the row's address", loose, async () => {
  const f = fake([row(1), row(2)]);
  const c = await f.run();
  assertEquals(f.keys, ["ms-1", "ms-2"]);
  assertEquals(f.to, ["o1@x.test", "o2@x.test"]);
  assertEquals(f.done, [[{ id: 1, code: 200 }, { id: 2, code: 200 }]]);
  assertEquals(c.sent, 2);
});

Deno.test("422 refused: failed, the next row still goes", loose, async () => {
  const f = fake([row(3), row(4)], { 3: { status: 422, error: "resend 422: bad address" } });
  const c = await f.run();
  assertEquals(f.done[0], [{ id: 3, code: 422, error: "resend 422: bad address" }, { id: 4, code: 200 }]);
  assertEquals([c.failed, c.sent], [1, 1]);
});

Deno.test("5xx: tried again by the database; the rest wait, untried", loose, async () => {
  const f = fake([row(5), row(6)], { 5: { status: 503, error: "resend 503: down" } });
  const c = await f.run();
  assertEquals(f.done[0], [{ id: 5, code: 503, error: "resend 503: down" }, { id: 6, untried: true }]);
  assertEquals(f.keys, ["ms-5"]);
  assertEquals(c.again, 2);
});

Deno.test("409: same key already sent with other words counts as sent; one still in progress is tried again", loose, async () => {
  const f = fake([row(7), row(8)], {
    7: { status: 409, error: 'resend 409: {"name":"invalid_idempotent_request"}' },
    8: { status: 409, error: 'resend 409: {"name":"concurrent_idempotent_requests"}' },
  });
  await f.run();
  assertEquals(f.done[0], [{ id: 7, code: 200 }, { id: 8, code: 409, error: 'resend 409: {"name":"concurrent_idempotent_requests"}' }]);
});

Deno.test("nothing to say: dropped; a build error: tried again, nothing sent", loose, async () => {
  const f = fake([row(9, { kind: "batt_hot_back" }), row(10)], {},
    (r: any) => r.kind === "batt_hot_back" ? Promise.resolve(null) : Promise.reject(new Error("no plant")));
  const c = await f.run();
  assertEquals(f.done[0], [{ id: 9, skip: "nothing to say" }, { id: 10, code: 0, error: "build: no plant" }]);
  assertEquals(f.keys, []);
  assertEquals([c.dropped, c.again], [1, 1]);
});

Deno.test("taken, then past the deadline: every row handed back untried, nothing built or sent", loose, async () => {
  const f = fake([row(11), row(12)], {}, () => Promise.reject(new Error("no build expected")));
  const now = Date.now();
  await f.run(now + 10_000, now - 1);
  assertEquals(f.done[0], [{ id: 11, untried: true }, { id: 12, untried: true }]);
  assertEquals(f.keys, []);
});

Deno.test("the RPC missing (functions out before the migration): noted, not fatal", loose, async () => {
  const c = await msgEmailPass(Date.now() + 1000, Date.now() + 1000,
    () => Promise.reject(new Error("msg_email_take: Could not find the function public.msg_email_take(p_lane, p_limit) in the schema cache")));
  assertEquals((c as { missing?: boolean }).missing, true);
});

// last: a 429 holds the shared pace for its Retry-After
Deno.test("429: Retry-After passed back in seconds, the rest wait untried", loose, async () => {
  const f = fake([row(13), row(14)], { 13: { status: 429, error: "resend 429", retryAfter: "2" } });
  const c = await f.run();
  assertEquals(f.done[0], [{ id: 13, code: 429, error: "resend 429", retry_s: 2 }, { id: 14, untried: true }]);
  assertEquals(c.again, 2);
});
