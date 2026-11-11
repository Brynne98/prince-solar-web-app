// deno test -A --node-modules-dir=none notify/history_test.ts (SOLAR-522)
import { HISTORY_HOLD_MS, historyHeld } from "./index.ts";

const eq = (a: unknown, b: unknown, what: string) => { if (a !== b) throw new Error(`${what}: ${a} !== ${b}`); };
const queued = "2026-11-11T22:17:00Z", at = (ms: number) => Date.parse(queued) + ms;

Deno.test("the 60-days email waits while the plant has no day totals", () => {
  eq(historyHeld(0, queued, at(10 * 60e3)), true, "10 min in, none");
  eq(historyHeld(0, queued, at(HISTORY_HOLD_MS - 1)), true, "just under 2 h");
});

Deno.test("it goes once day totals land, or after 2 hours", () => {
  eq(historyHeld(183, queued, at(10 * 60e3)), false, "rows landed");
  eq(historyHeld(0, queued, at(HISTORY_HOLD_MS)), false, "2 h up");
});
