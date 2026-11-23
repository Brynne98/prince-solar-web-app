// deno test -A --node-modules-dir=none _shared/links_test.ts (SOLAR-641 phase 4 fixes 5, 6, 10)
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { Refused, type Rpc, saveLogin, savePlantClaim } from "./links.ts";
import { outboxKey, sendOutboxOne } from "./outbox.ts";

const failing = (message: string): { rpc: Rpc; calls: string[] } => {
  const calls: string[] = [];
  return { calls, rpc: (fn, args) => { calls.push(`${fn}:${args.p_cmd}`); return Promise.resolve({ data: null, error: { message } }); } };
};
const notes: string[] = [];
const note = (what: string) => { notes.push(what); };

Deno.test("live: claim_plant's refusal is the answer (fix 5)", async () => {
  const { rpc } = failing("taken");
  const e = await assertRejects(() => savePlantClaim(rpc, true, note, "u", { id: 1, name: "A" }), Refused);
  assertEquals(e.answer, "taken");
});
Deno.test("live: an ended account's claim is refused as no plan (fix 5)", async () => {
  const { rpc } = failing("no plant can be added without a plan");
  const e = await assertRejects(() => savePlantClaim(rpc, true, note, "u", { id: 1, name: "A" }), Refused);
  assertEquals(e.answer, "no plan");
});
Deno.test("live: any other claim failure is an error, never a success (fix 5)", async () => {
  const { rpc } = failing("connection reset");
  await assertRejects(() => savePlantClaim(rpc, true, note, "u", { id: 1, name: "A" }), Error, "claim_plant");
});
Deno.test("before the switch: a failed copy is only noted", async () => {
  const { rpc } = failing("whatever");
  notes.length = 0;
  await savePlantClaim(rpc, false, note, "u", { id: 1, name: "A" });
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
Deno.test("outbox: 409 (the key already sent it) counts as sent (fix 10)", async () => {
  const post = () => Promise.resolve({ status: 409, error: "resend 409: idempotency key used" });
  assertEquals(await sendOutboxOne(post, "u", { id: 7, payload: {} }), { status: 200 });
});
