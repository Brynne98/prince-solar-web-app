// SUPABASE_URL=http://x SUPABASE_SERVICE_ROLE_KEY=x deno test -A --node-modules-dir=none notify-push/push_test.ts
// (SOLAR-645 step 3): outbox take/done and how each push service answer is reported.
import { assertEquals } from "jsr:@std/assert@1";
import * as webpush from "jsr:@negrel/webpush@0.5.0";
import { outboxPushPass, type PushSend, pushSend } from "../notify/index.ts";
import { run } from "./index.ts";

const row = (id: number, over: Partial<PushSend> = {}): PushSend => ({
  id, claim: "c-1", event_id: 100 + id, kind: "grid_down", plant_id: 7, title: "t", body: "b", tab: "grid", day: null,
  endpoint: `https://fcm.googleapis.com/fcm/send/dev-${id}`, p256dh: "k", auth: "a", ...over,
});
const refuse = (status: number, headers: Record<string, string> = {}) => () =>
  Promise.reject(new webpush.PushMessageError(new Response(null, { status, headers })));

Deno.test("2xx: code 201", async () => {
  let sent = "";
  const r = await pushSend(row(1), (_s, msg) => { sent = msg; return Promise.resolve(); });
  assertEquals(r, { id: 1, code: 201 });
  const m = JSON.parse(sent);
  assertEquals([m.tag, m.data.id, m.data.tab], ["7:grid", 101, "grid"]);
});

Deno.test("429 with Retry-After: code and seconds", async () => {
  assertEquals(await pushSend(row(2), refuse(429, { "retry-after": "7" })),
               { id: 2, code: 429, error: "push service 429", retry_s: 7 });
});

Deno.test("429 without Retry-After: no seconds, the database backs off", async () => {
  assertEquals(await pushSend(row(3), refuse(429)), { id: 3, code: 429, error: "push service 429" });
});

Deno.test("404 and 410: code passed on (device removed in the database)", async () => {
  assertEquals((await pushSend(row(4), refuse(404))).code, 404);
  assertEquals((await pushSend(row(5), refuse(410))).code, 410);
});

Deno.test("5xx: code passed on", async () => {
  assertEquals((await pushSend(row(6), refuse(503))).code, 503);
});

Deno.test("no answer: code 0", async () => {
  const r = await pushSend(row(7), () => Promise.reject(new TypeError("connection reset")));
  assertEquals([r.code, r.error], [0, "connection reset"]);
});

Deno.test("an address off the push services: 410, never called", async () => {
  let called = false;
  const r = await pushSend(row(8, { endpoint: "https://evil.example/x" }), () => { called = true; return Promise.resolve(); });
  assertEquals([r.code, called], [410, false]);
});

Deno.test("pass: take, send each device, done under the take's claim, until a take is empty", async () => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const takes = [[row(1), row(2)], []];
  const call = <T>(fn: string, args?: Record<string, unknown>) => {
    calls.push([fn, args]);
    return Promise.resolve((fn === "msg_push_take" ? takes.shift() : null) as T);
  };
  const send = (s: PushSend) => s.id === 2 ? refuse(429, { "retry-after": "3" })() : Promise.resolve();
  const count = await outboxPushPass(Date.now() + 10_000, call, send);
  assertEquals(calls.map((c) => c[0]), ["msg_push_take", "msg_push_done", "msg_push_take"]);
  assertEquals(calls[1][1], { p_claim: "c-1", p_results: [
    { id: 1, code: 201 }, { id: 2, code: 429, error: "push service 429", retry_s: 3 }] });
  assertEquals(count, { ok: 1, gone: 0, again: 1, failed: 0 });
});

Deno.test("notify-push: old path first, a failed outbox pass is noted, not fatal", async () => {
  const order: string[] = [];
  const out = await run({
    old: (d) => { order.push(`old:${d}`); return Promise.resolve({ ok: 1 }); },
    outbox: (d) => { order.push(`outbox:${d}`); return Promise.reject(new Error("msg_push_take: not found")); },
  }, 0);
  assertEquals(order, ["old:10000", "outbox:50000"]);
  assertEquals(out, { pushed: { ok: 1 }, outbox: { error: "msg_push_take: not found" } });
});
