// Each login's refresh minutes (SOLAR-650). The inverter list is re-read once in ten
// minutes and the plant list once an hour; when every login did both on the same minute
// (:00, :10, ...) those minutes carried all the extra SunSynk calls and detection writes.
// The minute comes from the login's uuid: its last 12 hex digits, away from the first 8
// the shard hash uses (0246), so the logins of one shard still spread. The hourly minute
// never falls on a list minute, so no login does both refreshes in one minute.
// Plain TypeScript with no imports: the test runs it under Node.

export const REFRESH_EVERY_MIN = 10;
export const PLANTS_EVERY_MIN = 60;

const idNumber = (id: string) => parseInt(id.replace(/-/g, "").slice(-12), 16) || 0;

/** 0-9: the minute of each ten the login re-reads its inverter list. */
export const listMinute = (id: string) => idNumber(id) % REFRESH_EVERY_MIN;

/** 0-59: the minute of each hour the login re-reads its plant list; never a list minute. */
export const plantsMinute = (id: string) =>
  (Math.floor(idNumber(id) / REFRESH_EVERY_MIN) % 6) * 10 + (listMinute(id) + 5) % REFRESH_EVERY_MIN;

/** Is `ts` (epoch seconds, on the minute) this login's list / plant refresh minute? */
export const isListMinute = (id: string, ts: number) => (ts / 60) % REFRESH_EVERY_MIN === listMinute(id);
export const isPlantsMinute = (id: string, ts: number) => (ts / 60) % PLANTS_EVERY_MIN === plantsMinute(id);
