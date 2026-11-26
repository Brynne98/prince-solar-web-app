// The brand registry (SOLAR-681 R15): code outside brands/ gets a login's adapter here and
// never imports one directly.
import type { Brand, Fetched, InverterInfo } from "./types.ts";
import { sunsynk } from "./sunsynk/index.ts";

export * from "./types.ts";

/**
 * R13: a brand other than the first stores its inverter serials as <code>:<serial>, so two brands'
 * serials never meet in a table keyed on the serial. The adapter sees the brand's own serial.
 */
export function withSerialPrefix(base: Brand, code: string, displayName: string): Brand {
  const pre = `${code}:`;
  const own = (sn: string) => (sn.startsWith(pre) ? sn.slice(pre.length) : sn);
  const theirs = (inv: InverterInfo): InverterInfo => ({ ...inv, sn: own(inv.sn) });
  const ours = (f: Fetched, inv: InverterInfo): Fetched => ({ ...f, inv });
  return {
    ...base, code, displayName,
    listInverters: async (acc) => (await base.listInverters(acc)).map((i) => ({ ...i, sn: pre + own(i.sn) })),
    readNow: async (inv, acc, ts, o) => ours(await base.readNow(theirs(inv), acc, ts, o), inv),
    todayTemps: (inv, acc, tz) => base.todayTemps(theirs(inv), acc, tz),
    stringRows: (f) => base.stringRows(f).map((r) => ({ ...r, sn: f.inv.sn })),
    metaRow: (f, ts, ord) => { const m = base.metaRow(f, ts, ord); return m && { ...m, sn: f.inv.sn }; },
    readingRow: (f, ts, tz) => ({ ...base.readingRow(f, ts, tz), sn: f.inv.sn }),
    history: {
      ...base.history,
      inverterDay: (acc, sn, day, web) => base.history.inverterDay(acc, own(sn), day, web),
      inverterExtras: (acc, sn, day, gridOnly) => base.history.inverterExtras(acc, own(sn), day, gridOnly),
    },
  };
}

// the fake plants testers link (logins ending @mock, SOLAR-270): the SunSynk adapter, which sends
// those logins to the fake, as a brand of their own (R14)
const mock = withSerialPrefix(sunsynk, "mock", "Test plants");

const BRANDS: Record<string, Brand> = { [sunsynk.code]: sunsynk, [mock.code]: mock };

/** The brand of a login by its username: the fake plants' own, else the first brand. */
export const brandForUsername = (username: string) => (username.toLowerCase().endsWith("@mock") ? mock.code : DEFAULT_BRAND);

/** The brand of a login made before logins had one, and of a link that names none. */
export const DEFAULT_BRAND = sunsynk.code;

/** The adapter for a brand code (a login's `brand`). */
export function brandOf(code: string): Brand {
  const b = BRANDS[code];
  if (!b) throw new Error(`brand_unknown: ${code}`);
  return b;
}

/** Every adapter, e.g. to save each one's call counts. */
export const allBrands = (): Brand[] => Object.values(BRANDS);

/** Saves every adapter's call counts; a poll run passes its shard, run time and plants. */
export async function saveAllCalls(run?: { shard: number; ms: number; plants: number }) {
  // brands that share one counter (mock is the SunSynk adapter) save it once, and the run log once
  const savers = [...new Set(allBrands().map((b) => b.saveCalls))];
  await Promise.all(savers.map((save, i) => save(i === 0 ? run : undefined)));
}
