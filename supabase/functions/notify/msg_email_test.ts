// SUPABASE_URL=http://x SUPABASE_SERVICE_ROLE_KEY=x deno test -A --node-modules-dir=none notify/msg_email_test.ts
// (SOLAR-645 step 4): alert emails from the message outbox: take, build, Resend batch calls under
// a key saved before the call (a row alone under ms-<id>), and what each answer reports back.
import { assertEquals } from "jsr:@std/assert@1";
import { type MsgEmail, msgEmailPass, type MsgResult } from "./index.ts";
import type { Email } from "../_shared/email.ts";

// The pace between calls is a timer that outlives a test.
const loose = { sanitizeResources: false, sanitizeOps: false };
const row = (id: number, over: Partial<MsgEmail> = {}): MsgEmail => ({
  id, claim: "c-1", tries: 1, batch_key: null, event_id: 100 + id, user_id: "u-1", to_email: `o${id}@x.test`, plant_id: 7,
  plant_name: "Home", tz: "Africa/Johannesburg", kind: "grid_down", key: `k${id}`, data: { since: 1_700_000_000 }, ...over,
});
const mail: Email = { subject: "s", html: "<p>h</p>", text: "t" } as Email;
type Ans = { status: number; error?: string; retryAfter?: string | null };
type Make = (r: { kind: string; id: number }) => Promise<Email | null>;

/** One take of `rows`, then an empty one. Resend answers from `answers` by key. Records every
 *  bind and call in order. */
function fake(rows: MsgEmail[], answers: Record<string, Ans> = {}, make: Make = () => Promise.resolve(mail),
              bindFails = false) {
  const done: MsgResult[][] = [], log: string[] = [];
  let takes = 0, keys = 0;
  const call = <T,>(fn: string, args?: Record<string, unknown>): Promise<T> => {
    if (fn === "msg_email_take") return Promise.resolve((takes++ ? [] : rows) as T);
    if (fn === "msg_email_bind") {
      log.push(`bind ${args!.p_key} ${(args!.p_ids as number[]).join(",")}`);
      return bindFails ? Promise.reject(new Error("msg_email_bind: 1 of 2 rows")) : Promise.resolve(true as T);
    }
    if (fn === "msg_email_done") { done.push(args!.p_results as MsgResult[]); return Promise.resolve(null as T); }
    throw new Error(fn);
  };
  const post = (url: string, body: any, key: string) => {
    log.push(`${url.endsWith("/batch") ? "batch" : "one"} ${key} ${[body].flat().map((b: any) => b.to[0]).join(",")}`);
    return Promise.resolve(answers[key] ?? { status: 200 });
  };
  return { done, log,
           run: (until = Date.now() + 20_000, deadline = until) =>
             msgEmailPass(until, deadline, call, post, make as any, () => `mb-t${++keys}`) };
}

Deno.test("new rows: one batch call, its key saved on the rows before the call", loose, async () => {
  const f = fake([row(1), row(2)]);
  const c = await f.run();
  assertEquals(f.log, ["bind mb-t1 1,2", "batch mb-t1 o1@x.test,o2@x.test"]);
  assertEquals(f.done, [[{ id: 1, code: 200 }, { id: 2, code: 200 }]]);
  assertEquals(c.sent, 2);
});

Deno.test("a row alone: its own call under ms-<id>, nothing saved", loose, async () => {
  const f = fake([row(3)]);
  await f.run();
  assertEquals(f.log, ["one ms-3 o3@x.test"]);
  assertEquals(f.done[0], [{ id: 3, code: 200 }]);
});

Deno.test("batch refused (422): each row alone, so only the bad one fails; keys cleared", loose, async () => {
  const f = fake([row(4), row(5)], { "mb-t1": { status: 422, error: "resend 422: bad" }, "ms-4": { status: 422, error: "resend 422: bad" } });
  const c = await f.run();
  assertEquals(f.log, ["bind mb-t1 4,5", "batch mb-t1 o4@x.test,o5@x.test", "one ms-4 o4@x.test", "one ms-5 o5@x.test"]);
  assertEquals(f.done[0], [{ id: 4, code: 422, error: "resend 422: bad" }, { id: 5, code: 200 }]);
  assertEquals([c.failed, c.sent], [1, 1]);
});

Deno.test("batch 5xx: every row again, key kept; the pass stops, the next group waits untried", loose, async () => {
  const many = Array.from({ length: 102 }, (_, i) => row(1000 + i));
  const f = fake(many, { "mb-t1": { status: 503, error: "resend 503" } });
  await f.run();
  const res = f.done[0];
  assertEquals(res.slice(0, 100).every((r) => r.code === 503 && r.keep === true), true);
  assertEquals(res.slice(100), [{ id: 1100, untried: true }, { id: 1101, untried: true }]);
  assertEquals(f.log.filter((l) => !l.startsWith("bind")).length, 1);
});

Deno.test("409: already sent with other words counts as sent; still in progress: again under the key, the pass goes on", loose, async () => {
  const f = fake([row(6, { batch_key: "mb-a" }), row(7, { batch_key: "mb-a" }), row(8, { batch_key: "mb-b" }), row(9, { batch_key: "mb-b" })], {
    "mb-a": { status: 409, error: 'resend 409: {"name":"invalid_idempotent_request"}' },
    "mb-b": { status: 409, error: 'resend 409: {"name":"concurrent_idempotent_requests"}' },
  });
  await f.run();
  const e = 'resend 409: {"name":"concurrent_idempotent_requests"}';
  assertEquals(f.done[0], [{ id: 6, code: 200 }, { id: 7, code: 200 }, { id: 8, code: 409, error: e, keep: true },
                           { id: 9, code: 409, error: e, keep: true }]);
});

Deno.test("a group bound by an earlier call: sent again whole under its own key, no new bind", loose, async () => {
  const f = fake([row(10, { batch_key: "mb-old" }), row(11, { batch_key: "mb-old" }), row(12)]);
  await f.run();
  assertEquals(f.log, ["batch mb-old o10@x.test,o11@x.test", "one ms-12 o12@x.test"]);
});

Deno.test("a bound group with one email that can't be built: the rest go under the key, that one waits with it", loose, async () => {
  const f = fake([row(13, { batch_key: "mb-x" }), row(14, { batch_key: "mb-x" })], {},
    (r) => r.id === 113 ? Promise.reject(new Error("no plant")) : Promise.resolve(mail));
  await f.run();
  assertEquals(f.log, ["batch mb-x o14@x.test"]);
  assertEquals(f.done[0], [{ id: 13, code: 0, error: "build: no plant", keep: true }, { id: 14, code: 200 }]);
});

Deno.test("a bound row left alone still goes in a batch call under its key", loose, async () => {
  const f = fake([row(27, { batch_key: "mb-w" })]);
  await f.run();
  assertEquals(f.log, ["batch mb-w o27@x.test"]);
});

Deno.test("new rows: nothing to say is dropped, a build error tried again, the rest sent", loose, async () => {
  const f = fake([row(15, { kind: "batt_hot_back" }), row(16), row(17)], {},
    (r) => r.kind === "batt_hot_back" ? Promise.resolve(null) : r.id === 116 ? Promise.reject(new Error("no plant")) : Promise.resolve(mail));
  const c = await f.run();
  assertEquals(f.log, ["one ms-17 o17@x.test"]);
  assertEquals(f.done[0], [{ id: 15, skip: "nothing to say" }, { id: 16, code: 0, error: "build: no plant" }, { id: 17, code: 200 }]);
  assertEquals([c.dropped, c.again, c.sent], [1, 1, 1]);
});

Deno.test("taken, then past the deadline: handed back untried; a bound group keeps its key", loose, async () => {
  const f = fake([row(18, { batch_key: "mb-y" }), row(19, { batch_key: "mb-y" }), row(20)], {}, () => Promise.reject(new Error("no build")));
  const now = Date.now();
  await f.run(now + 10_000, now - 1);
  assertEquals(f.log, []);
  assertEquals(f.done[0], [{ id: 18, untried: true, keep: true }, { id: 19, untried: true, keep: true }, { id: 20, untried: true }]);
});

Deno.test("the key can't be saved: nothing sent, rows back untried", loose, async () => {
  const f = fake([row(21), row(22)], {}, undefined, true);
  await f.run();
  assertEquals(f.log, ["bind mb-t1 21,22"]);
  assertEquals(f.done[0], [{ id: 21, untried: true }, { id: 22, untried: true }]);
});

Deno.test("the RPC missing (functions out before the migration): noted, not fatal", loose, async () => {
  const c = await msgEmailPass(Date.now() + 1000, Date.now() + 1000,
    () => Promise.reject(new Error("msg_email_take: Could not find the function public.msg_email_take(p_lane, p_limit) in the schema cache")));
  assertEquals((c as { missing?: boolean }).missing, true);
});

// last: a 429 holds the shared pace for its Retry-After
Deno.test("batch 429: Retry-After in seconds, key kept, the pass stops", loose, async () => {
  const f = fake([row(23), row(24), row(25, { batch_key: "mb-z" }), row(26, { batch_key: "mb-z" })],
    { "mb-z": { status: 429, error: "resend 429", retryAfter: "2" } });
  const c = await f.run();
  assertEquals(f.done[0], [{ id: 25, code: 429, error: "resend 429", retry_s: 2, keep: true },
                           { id: 26, code: 429, error: "resend 429", retry_s: 2, keep: true },
                           { id: 23, untried: true }, { id: 24, untried: true }]);
  assertEquals(c.again, 4);
});
