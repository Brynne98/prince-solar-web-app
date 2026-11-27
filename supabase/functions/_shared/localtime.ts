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
 * A local day's clock: its first and last epoch second (a day is 23, 24 or 25 hours long), and
 * the epoch of a wall-clock time on it. Brands send history at wall-clock times.
 */
export type DayClock = { start: number; end: number; at: (wallSec: number) => number };
export function dayClock(tz: string, day: string): DayClock {
  const start = dayStartEpoch(tz, day), end = dayStartEpoch(tz, nextDay(day));
  const plain = end - start === 86400 && offsetMin(tz, start * 1000) === offsetMin(tz, (end - 1) * 1000);
  return { start, end, at: plain ? (s) => start + s : (s) => wallEpoch(tz, day, s) };
}
