// deno test -A --node-modules-dir=none sync-plant-energy/grid_test.ts (SOLAR-522)
import { gridScale } from "./index.ts";

const eq = (a: unknown, b: unknown, what: string) => { if (a !== b) throw new Error(`${what}: ${a} !== ${b}`); };

Deno.test("a failed q_grid_feed_scale gives 1 and the error, not a throw", () => {
  const r = gridScale({ data: null, error: { message: "canceling statement due to statement timeout" } });
  eq(r.gridMul, 1, "gridMul");
  eq(r.gridErr, "q_grid_feed_scale: canceling statement due to statement timeout", "gridErr");
});

Deno.test("a good lookup keeps its multiplier", () => {
  eq(gridScale({ data: 2, error: null }).gridMul, 2, "two inverters, one CT");
  eq(gridScale({ data: 2, error: null }).gridErr, undefined, "no error");
  eq(gridScale({ data: null, error: null }).gridMul, 1, "null reads as 1");
  eq(gridScale({ data: 0, error: null }).gridMul, 1, "0 reads as 1");
});
