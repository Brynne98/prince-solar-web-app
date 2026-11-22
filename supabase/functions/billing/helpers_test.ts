// deno test supabase/functions/billing/helpers_test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { pool, refundIds, verifyStatus } from "./helpers.ts";

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
