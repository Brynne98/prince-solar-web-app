// deno test -A --node-modules-dir=none job-check/judge_test.ts (SOLAR-469, SOLAR-472)
import { judge } from "./index.ts";

const base = { now: "2026-11-10T21:00:00Z", shards: [], jobs: [], sunsynk: { calls: 0, failed: 0, since: null },
               email: { waiting: 0, oldest_due: null }, checks: {} };
const pick = (v: ReturnType<typeof judge>, n: string) => v.find((x) => x.name === n);
const eq = (a: unknown, b: unknown, what: string) => { if (a !== b) throw new Error(`${what}: ${a} !== ${b}`); };

Deno.test("a failed timed call flags call:<fn>; no outcome keeps the state", () => {
  const v = judge({ ...base, calls: [
    { fn: "notify", failing: true, result: "timeout", error: null, last_call: base.now, failed_1h: 1 },
    { fn: "recover", failing: null, result: null, error: null, last_call: null, failed_1h: 0 },
  ] });
  eq(pick(v, "call:notify")?.failing, true, "notify");
  eq(pick(v, "call:notify")?.job, "notify", "job");
  eq(pick(v, "call:recover")?.failing, null, "recover");
});

Deno.test("a call check of a function no longer called clears", () => {
  const v = judge({ ...base, calls: [], checks: { "call:billing": { failing: true, since: base.now } } });
  eq(pick(v, "call:billing")?.failing, false, "billing");
  eq(pick(v, "call:billing")?.job, "billing", "job");
});

Deno.test("sign-in mail: a bounce fails, a clean hour recovers, Infobip silent keeps it", () => {
  eq(pick(judge({ ...base, signin: { DELIVERED: 2, UNDELIVERABLE: 1 } }), "signin-email")?.failing, true, "bounce");
  eq(pick(judge({ ...base, signin: {} }), "signin-email")?.failing, false, "quiet");
  const kept = judge({ ...base, signin: null, checks: { "signin-email": { failing: true, since: base.now } } });
  eq(pick(kept, "signin-email"), undefined, "kept");
});
