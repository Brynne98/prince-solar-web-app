// deno test supabase/functions/billing/helpers_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { commandFailed, pool, refundIds, verifyStatus } from "./helpers.ts";

Deno.test("pool stops starting work once the budget is spent and returns what is left", async () => {
  let t = 0;
  const r = await pool([1, 2, 3, 4, 5], 2, 10, async (x) => { t += 4; return x * 10; }, () => t);
  assertEquals(r.done.length + r.left.length, 5);
  assertEquals(r.left.length > 0, true);
  assertEquals(r.done.every((x) => x % 10 === 0), true);
});

Deno.test("pool runs everything inside the budget", async () => {
  const r = await pool([1, 2, 3], 2, 1_000, async (x) => x);
  assertEquals(r.done.sort(), [1, 2, 3]);
  assertEquals(r.left, []);
});

Deno.test("verify reports how a try already settled by the webhook ended", () => {
  assertEquals(verifyStatus({ action: "again", status: "success" }), "applied");
  assertEquals(verifyStatus({ action: "again", status: "not_applied" }), "refund");
  assertEquals(verifyStatus({ action: "again", status: "failed" }), "failed");
  assertEquals(verifyStatus({ action: "again", status: "reversed" }), "refund");
  assertEquals(verifyStatus({ action: "again", status: "void" }), "failed");
  assertEquals(verifyStatus({ action: "applied" }), "applied");
  assertEquals(verifyStatus(null), "pending");
});

Deno.test("refund ids: id and refund_reference apart", () => {
  assertEquals(refundIds({ id: 7, refund_reference: "RF_9" }), { provider_id: "7", provider_ref: "RF_9" });
  assertEquals(refundIds({ refund_reference: "RF_9" }), { provider_id: null, provider_ref: "RF_9" });
  assertEquals(refundIds({}), { provider_id: null, provider_ref: null });
});

Deno.test("a refused command is the answer and is not reported; anything else is reported (go-live review)", () => {
  const notes: string[] = [];
  const note = (kind: string) => { notes.push(kind); };
  const err = (message: string, code: string) => Object.assign(new Error(message), { code });
  assertEquals(commandFailed(err("upgrade: pay the failed payment first", "22023"), note), { status: 409, error: "pay the failed payment first" });
  assertEquals(commandFailed(err("pay_now: nothing to pay", "P0002"), note), { status: 409, error: "nothing to pay" });
  assertEquals(notes, []);
  // a lock clash (Postgres cancels one side) or any other database fault: 500, and reported
  assertEquals(commandFailed(err("cancel: deadlock detected", "40P01"), note), { status: 500, error: "deadlock detected" });
  assertEquals(notes, ["billing_command_failed"]);
});
