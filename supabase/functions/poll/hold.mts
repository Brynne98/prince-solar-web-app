// Hold last good (SOLAR-551). For 20-40 s after an upload SunSynk serves each realtime
// endpoint old or new on its own, so one minute's read can mix two uploads and solar +
// grid + battery stops matching home. When an inverter's row is off by more than
// HOLD_GAP_W, its previous row (the minute before) balanced, and the gap jumped by more
// than HOLD_GAP_W since then, the previous row's four power figures are stored again for
// this minute. Counters, SOC, volts, relay and device_time stay as read.
// The jump test keeps a plant whose own loss sits near 400 W (495944 at high load) from
// holding on real minutes: a mixed read jumps, a steady loss does not.
// `held` on the row counts the run (1..MAX_HOLD_RUN; null when not held, column 0216).
// After MAX_HOLD_RUN held minutes what was read is stored. A held row balances, so it
// counts as good for the next minute. canCarry() refuses to carry the minute after a
// hold, or carried rows would copy the held figures forward unmarked.
// Plain TypeScript with no imports: the replay test runs it under Node.

export const HOLD_GAP_W = 400;
export const MAX_HOLD_RUN = 5;
const POWER = ["pv_w", "batt_w", "grid_w", "load_w"] as const;

/** pv + grid − batt − load (batt + = charging, grid + = import); null when a figure is missing. */
export function ownGap(r: Record<string, unknown>): number | null {
  const v = POWER.map((k) => r[k]);
  if (v.some((x) => x == null || !Number.isFinite(Number(x)))) return null;
  const [pv, batt, grid, load] = v.map(Number);
  return pv + grid - batt - load;
}

/** Applies the hold to `row` in place, given the inverter's previous stored row. */
export function holdLastGood(row: Record<string, unknown>, prev: Record<string, unknown> | null | undefined): void {
  row.held = null;
  if (!prev || Number(prev.ts) !== Number(row.ts) - 60) return;
  const run = Number(prev.held) || 0;
  const gap = ownGap(row), prevGap = ownGap(prev);
  if (gap == null || prevGap == null || run >= MAX_HOLD_RUN) return;
  if (Math.abs(gap) <= HOLD_GAP_W || Math.abs(prevGap) > HOLD_GAP_W) return;
  if (Math.abs(gap - prevGap) <= HOLD_GAP_W) return;
  for (const k of POWER) row[k] = prev[k];
  row.held = run + 1;
}
