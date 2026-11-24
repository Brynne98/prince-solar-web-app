// deno test -A --node-modules-dir=none notify-email/drain_test.ts (SOLAR-645 step 2)
import { assertEquals } from "jsr:@std/assert@1";
import { BILLING_MS, BULK_MS, DEADLINE_MS, drain, type Passes, URGENT_MS } from "./index.ts";

const record = () => {
  const calls: string[] = [];
  const p: Passes = {
    sweep: () => { calls.push("sweep"); return Promise.resolve({}); },
    alerts: (until, deadline) => { calls.push(`alerts:${until}:${deadline}`); return Promise.resolve({}); },
    billing: (until, deadline) => { calls.push(`billing:${until}:${deadline}`); return Promise.resolve({}); },
    bulkOutbox: (until, deadline) => { calls.push(`bulkOutbox:${until}:${deadline}`); return Promise.resolve({}); },
  };
  return { calls, p };
};

Deno.test("order: sweep, alert emails, billing, the rest", async () => {
  const { calls, p } = record();
  await drain(p, 0, false);
  assertEquals(calls, ["sweep", `alerts:${URGENT_MS}:${DEADLINE_MS}`, `billing:${BILLING_MS}:${DEADLINE_MS}`,
                       `bulkOutbox:${BULK_MS}:${DEADLINE_MS}`]);
});

Deno.test("each lane stops claiming before the cron call's 55 s", () => {
  assertEquals(URGENT_MS < BILLING_MS && BILLING_MS <= BULK_MS && BULK_MS < DEADLINE_MS && DEADLINE_MS < 55_000, true);
});

Deno.test("dry: no pass runs", async () => {
  const { calls, p } = record();
  assertEquals(await drain(p, 0, true), { live: false });
  assertEquals(calls, []);
});

Deno.test("a failed billing pass stops nothing after it", async () => {
  const { calls, p } = record();
  p.billing = () => Promise.reject(new Error("down"));
  const out = await drain(p, 0, false);
  assertEquals(calls.slice(-1).map((c) => c.split(":")[0]), ["bulkOutbox"]);
  assertEquals((out.billing as { error: string }).error, "down");
});

Deno.test("a failed outbox alert pass stops nothing after it", async () => {
  const { calls, p } = record();
  p.alerts = () => Promise.reject(new Error("down"));
  const out = await drain(p, 0, false);
  assertEquals(calls.map((c) => c.split(":")[0]), ["sweep", "billing", "bulkOutbox"]);
  assertEquals((out.alerts as { error: string }).error, "down");
});

Deno.test("a failed outbox bulk pass is reported, not thrown", async () => {
  const { p } = record();
  p.bulkOutbox = () => Promise.reject(new Error("down"));
  const out = await drain(p, 0, false);
  assertEquals((out.bulkOutbox as { error: string }).error, "down");
});
