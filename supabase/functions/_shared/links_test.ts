// deno test -A --node-modules-dir=none _shared/links_test.ts (SOLAR-641 phase 4 fixes 5, 6, 10)
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { claimAny, loginName, Refused, type Rpc, saveLogin, saveLoginLive } from "./links.ts";
import { outboxKey, sendOutboxOne } from "./outbox.ts";

const failing = (message: string): { rpc: Rpc; calls: string[] } => {
  const calls: string[] = [];
  return { calls, rpc: (fn, args) => { calls.push(`${fn}:${args.p_cmd}`); return Promise.resolve({ data: null, error: { message } }); } };
};
const notes: string[] = [];
const note = (what: string) => { notes.push(what); };

const answering = (data: unknown): { rpc: Rpc; calls: string[] } => {
  const calls: string[] = [];
  return { calls, rpc: (fn) => { calls.push(fn); return Promise.resolve({ data, error: null }); } };
};
const plant = { id: 1, name: "A" };
Deno.test("live: claim_plant's refusal is the answer (fix 5)", async () => {
  const { rpc } = failing("taken");
  const e = await assertRejects(() => claimAny(rpc, note, "u", "sh", plant), Refused);
  assertEquals(e.answer, "taken");
});
Deno.test("live: an ended account's claim is refused as no plan (fix 5)", async () => {
  const { rpc } = failing("no plant can be added without a plan");
  const e = await assertRejects(() => claimAny(rpc, note, "u", "sh", plant), Refused);
  assertEquals(e.answer, "no plan");
});
Deno.test("live: any other claim failure is an error, never a success (fix 5)", async () => {
  const { rpc } = failing("connection reset");
  await assertRejects(() => claimAny(rpc, note, "u", "sh", plant), Error, "share_claim_any");
});
Deno.test("a claim is one call, the switch read inside it (final re-score, Sol)", async () => {
  const { rpc, calls } = answering({ result: "claimed", copy_error: null });
  notes.length = 0;
  assertEquals(await claimAny(rpc, note, "u", "sh", plant), "claimed");
  assertEquals(calls, ["share_claim_any"]);
  assertEquals(notes, []);
});
Deno.test("before the switch: a failed copy is only noted", async () => {
  const { rpc } = answering({ result: "yours", copy_error: "whatever" });
  notes.length = 0;
  assertEquals(await claimAny(rpc, note, "u", "sh", plant), "yours");
  assertEquals(notes, ["claim_plant_failed"]);
});
Deno.test("live: link_login's refusal stops the link (fix 6)", async () => {
  const { rpc, calls } = failing("one login during the free week");
  const e = await assertRejects(() => saveLogin(rpc, true, note, "u", "acc", "me@x", [{ id: 1, name: "A" }]), Refused);
  assertEquals(e.answer, "one login");
  assertEquals(calls, ["billing_links:link_login"]);
});
Deno.test("live: a link_login failure is an error (fix 6)", async () => {
  const { rpc } = failing("deadlock detected");
  await assertRejects(() => saveLogin(rpc, true, note, "u", "acc", "me@x", []), Error, "link_login");
});

// fix 10: one key per outbox row, whatever else is due
Deno.test("outbox: the key is the row's own, so a retry in another batch keeps it (fix 10)", async () => {
  const keys: string[] = [];
  const post = (_u: string, _b: unknown, key: string) => { keys.push(key); return Promise.resolve({ status: 200 }); };
  await sendOutboxOne(post, "u", { id: 7, payload: {} });
  await sendOutboxOne(post, "u", { id: 8, payload: {} });
  await sendOutboxOne(post, "u", { id: 7, payload: { changed: true } });
  assertEquals(keys, [outboxKey(7), outboxKey(8), outboxKey(7)]);
});
Deno.test("outbox: 409, the key already sent it with other words: sent (final fix 12)", async () => {
  const post = () => Promise.resolve({ status: 409, error: 'resend 409: {"statusCode":409,"name":"invalid_idempotent_request"}' });
  assertEquals(await sendOutboxOne(post, "u", { id: 7, payload: {} }), { status: 200 });
});
Deno.test("outbox: 409 while the first call is in progress, or unnamed: retried, not sent (final fix 12)", async () => {
  for (const error of ['resend 409: {"name":"concurrent_idempotent_requests"}', "resend 409: conflict"]) {
    const post = () => Promise.resolve({ status: 409, error });
    assertEquals((await sendOutboxOne(post, "u", { id: 7, payload: {} })).status, 409);
  }
});

// final fixes 3, 4, 5: one case for a login; live linking and claiming in one transaction
Deno.test("a login's email in one case, trimmed (final fix 3)", () => {
  assertEquals(loginName("  Me@Mail.TEST "), "me@mail.test");
});
Deno.test("live link: one call, a refusal is the answer (final fix 4)", async () => {
  const { rpc, calls } = failing("one login");
  const e = await assertRejects(() => saveLoginLive(rpc, "u", "me@x", { access: "a", expires: 1, refresh: "r" }, []), Refused);
  assertEquals(e.answer, "one login");
  assertEquals(calls, ["link_login_live:undefined"]);
});
Deno.test("live claim: one call, taken is the answer (final fix 5)", async () => {
  const { rpc, calls } = failing("taken");
  const e = await assertRejects(() => claimAny(rpc, note, "u", "share", { id: 1, name: "A" }), Refused);
  assertEquals(e.answer, "taken");
  assertEquals(calls, ["share_claim_any:undefined"]);
});
