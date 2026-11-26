// A new day's first rows (SOLAR-648). Until an inverter's first upload after the plant's
// midnight, its "today" counters are still yesterday's: a carried or skipped row copies
// them, a failed endpoint falls back to the last row's, and the brand itself serves yesterday's
// battery and grid counters (495944 read 19.8 kWh charged at 00:00 on most nights). The
// inverter resets its counters at its own midnight, so an upload dated before the row's day
// holds yesterday's figures whatever its clock says, and today so far is 0.
// Plain TypeScript with no imports: scripts/newday-test.mjs runs it under Node.

export const TODAY_COUNTERS: ReadonlySet<string> = new Set([
  "pv_today_kwh", "load_today_kwh", "batt_chg_today_kwh", "batt_dischg_today_kwh",
  "grid_import_today_kwh", "grid_export_today_kwh",
]);

// one formatter per zone: building one costs far more than using it, and every row asks
const fmts = new Map<string, Intl.DateTimeFormat>();

/** The plant's date (YYYY-MM-DD) at an epoch in seconds. */
export function localDay(tz: string, epochS: number): string {
  let f = fmts.get(tz);
  if (!f) fmts.set(tz, f = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }));
  return f.format(new Date(epochS * 1000));
}

/** True when the last row is from an earlier day than this minute's. */
export function dayTurned(tz: string, ts: number, prev: Record<string, unknown> | null | undefined): boolean {
  const p = Number(prev?.ts);
  return Number.isFinite(p) && p > 0 && localDay(tz, p) < localDay(tz, ts);
}

/** A value taken from the last row: a today counter does not cross the plant's midnight. */
export function fromPrev(col: string, prevVal: unknown, turned: boolean): unknown {
  return turned && TODAY_COUNTERS.has(col) ? 0 : (prevVal ?? null);
}

/** An upload dated before the row's own day: every today counter is 0. Applied in place. */
export function clearYesterday(row: Record<string, unknown>, tz: string): void {
  const dt = row.device_time;
  if (typeof dt !== "string" || !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(dt)) return;
  if (dt.slice(0, 10) >= localDay(tz, Number(row.ts))) return;
  for (const col of TODAY_COUNTERS) if (row[col] != null) row[col] = 0;
}
