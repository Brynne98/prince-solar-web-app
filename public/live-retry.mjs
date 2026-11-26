// The page's one retry for a minute not saved yet (SOLAR-681 R22, Brynne 2026-11-27). The page
// asks at its plant's own second, 12-42 s past the minute (SOLAR-70); a reading that lands after
// that ask is asked for once more 5 s later, then the page waits for the next minute.
export const RETRY_MS = 5000;

/**
 * The plant is sending (its newest reading within `freshMs` of the server's clock) and that
 * reading is from an earlier minute than the server's: this minute's has not been saved yet.
 * `last` and `at` are Dates (or epoch ms): the reading's minute and the answer's server time.
 */
export function minuteMissing(last, at, freshMs) {
  if (last == null || at == null) return false;
  const l = +last, t = +at;
  if (!(t - l < freshMs)) return false;
  return Math.floor(l / 60000) < Math.floor(t / 60000);
}
