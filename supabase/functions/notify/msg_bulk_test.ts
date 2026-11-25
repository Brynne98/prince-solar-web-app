// SUPABASE_URL=http://x SUPABASE_SERVICE_ROLE_KEY=x deno test -A --node-modules-dir=none notify/msg_bulk_test.ts
// (SOLAR-645 step 5): the bulk emails from the message outbox: the bulk lane's take, the old
// path's holds before the build, feedback alone with its screenshot, account deleted to the
// captured address, and the PostHog counts after a send.
import { assertEquals } from "jsr:@std/assert@1";
import { type Hold, type MsgEmail, msgEmailPass, type MsgResult, type Row, trackSent } from "./index.ts";
import type { Email } from "../_shared/email.ts";

// The pace between calls is a timer that outlives a test.
const loose = { sanitizeResources: false, sanitizeOps: false };
const row = (id: number, over: Partial<MsgEmail> = {}): MsgEmail => ({
  id, claim: "c-1", tries: 1, batch_key: null, event_id: 100 + id, user_id: "u-1", to_email: `o${id}@x.test`, plant_id: 7,
  plant_name: "Home", tz: "Africa/Johannesburg", kind: "welcome", key: `k${id}`, data: {}, ...over,
});
const mail: Email = { subject: "s", html: "<p>h</p>", text: "t" } as Email;
const noHold: Hold = () => Promise.resolve(null);

function fake(rows: MsgEmail[], opts: { make?: (r: Row) => Promise<Email | null>; hold?: Hold } = {}) {
  const done: MsgResult[][] = [], log: string[] = [], bodies: any[] = [], takes: unknown[] = [];
  let n = 0, keys = 0;
  const call = <T,>(fn: string, args?: Record<string, unknown>): Promise<T> => {
    if (fn === "msg_email_take") { takes.push(args); return Promise.resolve((n++ ? [] : rows) as T); }
    if (fn === "msg_email_bind") { log.push(`bind ${args!.p_key}`); return Promise.resolve(true as T); }
    if (fn === "msg_email_done") { done.push(args!.p_results as MsgResult[]); return Promise.resolve(null as T); }
    throw new Error(fn);
  };
  const post = (url: string, body: any, key: string) => {
    log.push(`${url.endsWith("/batch") ? "batch" : "one"} ${key} ${[body].flat().map((b: any) => b.to[0]).join(",")}`);
    bodies.push(body);
    return Promise.resolve({ status: 200 });
  };
  return { done, log, bodies, takes,
           run: () => msgEmailPass(Date.now() + 20_000, Date.now() + 20_000, call, post,
                                   opts.make ?? (() => Promise.resolve(mail)), () => `mb-t${++keys}`, "bulk", opts.hold ?? noHold) };
}

Deno.test("the bulk pass takes the bulk lane", loose, async () => {
  const f = fake([row(1), row(2)]);
  await f.run();
  assertEquals(f.takes[0], { p_limit: 100, p_lane: "bulk" });
  assertEquals(f.log, ["bind mb-t1", "batch mb-t1 o1@x.test,o2@x.test"]);
});

Deno.test("a hold hands the row back unbuilt, the rest go; counted as held", loose, async () => {
  const built: number[] = [];
  const f = fake([row(3, { kind: "report_week" }), row(4), row(5)], {
    hold: (r) => Promise.resolve(r.kind === "report_week" ? { hold_s: 600, error: "waits for history" } : null),
    make: (r) => { built.push(r.id); return Promise.resolve(mail); },
  });
  const c = await f.run();
  assertEquals(built, [104, 105]);
  assertEquals(f.done[0], [{ id: 3, hold_s: 600, error: "waits for history" }, { id: 4, code: 200 }, { id: 5, code: 200 }]);
  assertEquals([c.held, c.sent], [1, 2]);
});

Deno.test("history with nothing to say yet: held an hour; an empty report is dropped", loose, async () => {
  const f = fake([row(6, { kind: "history" }), row(7, { kind: "report_week" })], { make: () => Promise.resolve(null) });
  const c = await f.run();
  assertEquals(f.done[0], [{ id: 6, hold_s: 3600, error: "nothing to say yet" }, { id: 7, skip: "nothing to say" }]);
  assertEquals([c.held, c.dropped], [1, 1]);
});

Deno.test("a bound row is never held: its call may have gone", loose, async () => {
  const f = fake([row(8, { kind: "history", batch_key: "mb-old" }), row(9, { kind: "history", batch_key: "mb-old" })], {
    hold: () => Promise.resolve({ hold_s: 600, error: "waits for day totals" }),
  });
  await f.run();
  assertEquals(f.log, ["batch mb-old o8@x.test,o9@x.test"]);
});

Deno.test("feedback goes alone under ms-<id>, screenshot attached, reply to the sender; the rest batch", loose, async () => {
  const fb = row(10, { kind: "feedback", user_id: "u-2", to_email: "hello@princesolarhub.co.za", plant_id: null,
    data: { id: 41, email: "sender@x.test", message: "hi", page: "live", version: "1", user: "u-2", image: "QUJD" } });
  const f = fake([row(11), fb, row(12)]);
  await f.run();
  assertEquals(f.log, ["one ms-10 hello@princesolarhub.co.za", "bind mb-t1", "batch mb-t1 o11@x.test,o12@x.test"]);
  const one = f.bodies[0];
  assertEquals(one.reply_to, "sender@x.test");
  assertEquals(one.attachments, [{ filename: "screenshot.jpg", content: "QUJD" }]);
});

Deno.test("account deleted: no user, sent to the address on the row", loose, async () => {
  const f = fake([row(13, { kind: "account_deleted", user_id: null, plant_id: null, to_email: "gone@x.test" })]);
  await f.run();
  assertEquals(f.log, ["one ms-13 gone@x.test"]);
  assertEquals(f.done[0], [{ id: 13, code: 200 }]);
});

Deno.test("PostHog: need a hand counted after it went, keyed on the event row, with choose", async () => {
  const sent: unknown[] = [];
  const send = (e: string, u: string, once: string, _at: string, p: Record<string, unknown> = {}) => {
    sent.push([e, u, once, p]); return Promise.resolve();
  };
  const r = (kind: string, data: Record<string, unknown> = {}, user: string | null = "u-1") =>
    ({ id: 77, user_id: user, kind, data } as unknown as Row);
  await trackSent(r("need_a_hand", { choose: true }), send);
  await trackSent(r("welcome"), send);
  await trackSent(r("account_deleted", {}, null), send);
  await trackSent(r("add_plant_reminder"), send);
  assertEquals(sent, [["need_a_hand_email_sent_done", "u-1", "77", { choose: true }],
    ["add_plant_reminder_email_sent_done", "u-1", "77", {}]]);
});
