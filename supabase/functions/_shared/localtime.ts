// Local dates in a plant's own zone (moved out of invhistory.ts, SOLAR-681).
/** YYYY-MM-DD in the plant's zone (moved here from recover). */
export function localDate(tz: string, d = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(d);
}

/** Minutes the zone is ahead of UTC at an instant (epoch ms). */
function offsetMin(tz: string, ms: number): number {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(ms)).map((x) => [x.type, x.value]));
  const wall = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour % 24, +p.minute, +p.second);
  return Math.round((wall - Math.floor(ms / 1000) * 1000) / 60000);
}

/** Epoch seconds of a wall-clock time (seconds past local midnight) on a local day. */
function wallEpoch(tz: string, day: string, wallSec: number): number {
  const [y, m, d] = day.split("-").map(Number);
  const asUtc = Date.UTC(y, m - 1, d) + wallSec * 1000;
  // the offset at the guess, then at the answer: right on either side of a clock change (SOLAR-686 H20)
  let t = asUtc - offsetMin(tz, asUtc) * 60000;
  t = asUtc - offsetMin(tz, t) * 60000;
  return Math.floor(t / 1000);
}

/** Epoch of local midnight for a YYYY-MM-DD in `tz`. The offset at midnight, not at noon. */
export const dayStartEpoch = (tz: string, day: string): number => wallEpoch(tz, day, 0);

const nextDay = (day: string) => {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + 1)).toISOString().slice(0, 10);
};

/**
 * A local day's clock: its first and last epoch second (a day is 23, 24 or 25 hours long), the
 * epoch of a wall-clock time on it, and the wall-clock time of an epoch. Brands send history at
 * wall-clock times. On the day the clocks go back an hour repeats: a time in its second pass is
 * given as wall seconds + 86400 (the adapter sees the brand's times step back, SECOND_PASS).
 */
export const SECOND_PASS = 86400;
export type DayClock = { start: number; end: number; at: (wallSec: number) => number; wall: (epoch: number) => number };
export function dayClock(tz: string, day: string): DayClock {
  const start = dayStartEpoch(tz, day), end = dayStartEpoch(tz, nextDay(day));
  const off0 = offsetMin(tz, start * 1000);
  const plain = end - start === 86400 && off0 === offsetMin(tz, (end - 1) * 1000);
  if (plain) return { start, end, at: (s) => start + s, wall: (e) => e - start };
  // a wall time is the before-change or after-change offset; in the repeated hour both are real
  // (the first pass is the earlier), in the skipped hour neither (the before-change one is used)
  const off1 = offsetMin(tz, (end - 1) * 1000);
  const [y, m, d] = day.split("-").map(Number);
  const at = (s: number) => {
    const late = s >= SECOND_PASS, w = late ? s - SECOND_PASS : s;
    const asUtc = Date.UTC(y, m - 1, d) / 1000 + w;
    const real = [asUtc - off0 * 60, asUtc - off1 * 60].filter((t) => offsetMin(tz, t * 1000) * 60 === asUtc - t);
    if (!real.length) return asUtc - off0 * 60;
    return late ? Math.max(...real) : Math.min(...real);
  };
  return { start, end, at, wall: (e) => e - start + (offsetMin(tz, e * 1000) - off0) * 60 };
}
