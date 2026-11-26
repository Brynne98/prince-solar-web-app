// deno test -A --node-modules-dir=none _shared/pace_test.ts (SOLAR-645 step 2)
import { assertEquals } from "jsr:@std/assert@1";
import { Pacer, readRate, retryAfterMs } from "./pace.ts";

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

// SOLAR-679 F14: the gap from each reply's rate-limit headers.
const rateHeaders = (remaining: string, reset: string) => new Headers({ "ratelimit-limit": "10", "ratelimit-remaining": remaining, "ratelimit-reset": reset });

Deno.test("readRate: remaining and reset, or null without them", () => {
  assertEquals(readRate(rateHeaders("9", "1")), { remaining: 9, resetS: 1 });
  assertEquals(readRate(new Headers()), null);
  assertEquals(readRate(new Headers({ "ratelimit-remaining": "x", "ratelimit-reset": "1" })), null);
});

Deno.test("10 a second: 25 calls go in 2 s, none refused (the fixed 550 ms gap took 13.2 s)", async () => {
  // a stand-in for the provider's window: 10 calls a second, the headers it would send
  const { c, now, sleep } = clock();
  const p = new Pacer(550, now, sleep);
  const start = c.t;
  let windowStart = c.t, used = 0, refused = 0;
  for (let i = 0; i < 25; i++) {
    await p.slot();
    if (c.t - windowStart >= 1000) { windowStart += Math.floor((c.t - windowStart) / 1000) * 1000; used = 0; }
    if (used >= 10) { refused++; continue; }
    used++;
    p.learn({ remaining: 10 - used, resetS: Math.ceil((windowStart + 1000 - c.t) / 1000) });
  }
  assertEquals(refused, 0);
  assertEquals(c.t - start, 2000);
});

Deno.test("none left in the window: the next call waits for the reset", async () => {
  const { c, now, sleep } = clock();
  const p = new Pacer(550, now, sleep);
  await p.slot();
  p.learn({ remaining: 0, resetS: 2 });
  await p.slot();
  assertEquals(c.slept, [2000]);
});

Deno.test("calls left: the next goes at once; a reply without headers falls back to the gap", async () => {
  const { c, now, sleep } = clock();
  const p = new Pacer(550, now, sleep);
  await p.slot();
  p.learn({ remaining: 4, resetS: 1 });
  await p.slot();
  p.learn(null);
  await p.slot();
  assertEquals(c.slept, [550]);
});

Deno.test("a 429 after the headers: Retry-After still wins", async () => {
  const { c, now, sleep } = clock();
  const p = new Pacer(550, now, sleep);
  await p.slot();
  p.learn({ remaining: 0, resetS: 1 });
  p.hold("5");
  await p.slot();
  assertEquals(c.slept, [5000]);
});

Deno.test("a long reset (an hourly quota) waits at most a minute, like Retry-After", async () => {
  const { c, now, sleep } = clock();
  const p = new Pacer(550, now, sleep);
  await p.slot();
  p.learn({ remaining: 0, resetS: 3600 });
  await p.slot();
  assertEquals(c.slept, [60_000]);
});
