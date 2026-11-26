// Local dates in a plant's own zone (moved out of invhistory.ts, SOLAR-681).
/** YYYY-MM-DD in the plant's zone (moved here from recover). */
export function localDate(tz: string, d = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(d);
}

/** Epoch of local midnight for a YYYY-MM-DD in `tz` (moved here from recover). */
export function dayStartEpoch(tz: string, day: string): number {
  // Find the UTC instant whose wall-clock in `tz` is 00:00 on `day`: start from
  // noon UTC that date and subtract the zone's offset at that instant.
  const [y, m, d] = day.split("-").map(Number);
  const noonUtc = Date.UTC(y, m - 1, d, 12);
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: tz, hour12: false, hour: "2-digit", minute: "2-digit" })
    .formatToParts(new Date(noonUtc));
  const hh = Number(parts.find((p) => p.type === "hour")?.value ?? "12") % 24;
  const mm = Number(parts.find((p) => p.type === "minute")?.value ?? "0");
  const offsetMin = (hh * 60 + mm) - 12 * 60;      // zone is `offset` ahead of UTC
  return Math.floor(noonUtc / 1000) - 12 * 3600 - offsetMin * 60;
}
