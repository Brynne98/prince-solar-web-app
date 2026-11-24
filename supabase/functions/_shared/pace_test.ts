// deno test -A --node-modules-dir=none _shared/pace_test.ts (SOLAR-645 step 2)
import { assertEquals } from "jsr:@std/assert@1";
import { Pacer, retryAfterMs } from "./pace.ts";

// A clock that only moves when the pacer sleeps.
const clock = () => {
  const c = { t: 1_000_000, slept: [] as number[] };
  return { c, now: () => c.t, sleep: (ms: number) => { c.slept.push(ms); c.t += ms; return Promise.resolve(); } };
};

Deno.test("calls go one gap apart", async () => {
  const { c, now, sleep } = clock();
  const p = new Pacer(550, now, sleep);
  for (let i = 0; i < 3; i++) assertEquals(await p.slot(), true);
  assertEquals(c.slept, [550, 550]);
});

Deno.test("a 429 holds the next call until Retry-After", async () => {
  const { c, now, sleep } = clock();
  const p = new Pacer(550, now, sleep);
  await p.slot();
  p.hold("7");
  await p.slot();
  assertEquals(c.slept, [7000]);
});

Deno.test("a slot past the deadline is refused without waiting", async () => {
  const { c, now, sleep } = clock();
  const p = new Pacer(550, now, sleep);
  await p.slot();
  p.hold("30");
  assertEquals(await p.slot(c.t + 10_000), false);
  assertEquals(c.slept, []);
});

Deno.test("Retry-After: seconds, a date, missing, capped at a minute", () => {
  const now = Date.parse("2026-11-24T20:00:00Z");
  assertEquals(retryAfterMs("2", now), 2000);
  assertEquals(retryAfterMs("Tue, 24 Nov 2026 20:00:05 GMT", now), 5000);
  assertEquals(retryAfterMs(null, now), 1000);
  assertEquals(retryAfterMs("junk", now), 1000);
  assertEquals(retryAfterMs("3600", now), 60_000);
  assertEquals(retryAfterMs("-5", now), 0);
});
