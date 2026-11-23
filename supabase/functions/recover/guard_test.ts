// deno test -A --node-modules-dir=none recover/guard_test.ts (SOLAR-641 phase 3 fixes 12, 13)
import { assertEquals } from "jsr:@std/assert@1";
import { guardedWrite, newGuard, spineFailed } from "./guard.ts";

Deno.test("fix 12: each fetch carries its own version and refusal", async () => {
  const calls: Record<string, unknown>[] = [];
  const rpc = (_fn: string, args: Record<string, unknown>) => {
    calls.push(args);
    if (args.p_version === 1) return Promise.reject(new Error("q_insert_recovered_v2: plant 7 is not read now"));
    return Promise.resolve(5);
  };
  // two requests on the same plant at once, handed out on different versions
  const old = newGuard(1), fresh = newGuard(2);
  const [a, b] = await Promise.all([guardedWrite(rpc, "q_insert_recovered_v2", 7, old, {}),
    guardedWrite(rpc, "q_insert_recovered_v2", 7, fresh, {})]);
  assertEquals([a, b], [0, 5]);
  assertEquals([old.refused, fresh.refused], [true, false]);
  assertEquals(calls.map((c) => c.p_version).sort(), [1, 2]);
});

Deno.test("fix 12: any other error still throws", async () => {
  const g = newGuard(3);
  let threw = false;
  try { await guardedWrite(() => Promise.reject(new Error("timeout")), "q_insert_recovered_v2", 7, g, {}); }
  catch { threw = true; }
  assertEquals([threw, g.refused], [true, false]);
});

Deno.test("fix 13: a history-only day whose write threw is failed, so it is retried", () => {
  const r = spineFailed("2026-11-20", 1440, new Error("q_insert_inverter_history_v2: deadlock"));
  assertEquals([r.failed, r.banked, r.missing], [true, 0, 1440]);
});
