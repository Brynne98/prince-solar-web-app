// SunSynk plant-level feed helpers, ported from server.js.
//
// Two consumers: `recover` (per-day 5-min feed, to backfill logger-offline minutes)
// and `sync-plant-energy` (daily/monthly kWh totals, which reach back to the plant's
// commission date and so cannot be derived from our own history).
import { type Account, apiGet } from "./sunsynk.ts";
import { num } from "./extract.ts";

/** Map a SunSynk plant-feed series label to our key. */
export function plantSeriesKey(label: string): string | null {
  const s = String(label || "").toLowerCase();
  if (s.includes("pv") || s.includes("solar")) return "pv";
  if (s.includes("batt")) return "batt";
  if (s.includes("soc") || s.includes("charge")) return "soc";
  if (s.includes("load")) return "load";
  if (s.includes("grid")) return "grid";
  return null;
}

/** Map an energy-endpoint label to our kWh key. */
export function energyKey(label: string): string | null {
  const s = String(label || "").toLowerCase();
  if (s.includes("pv") || s.includes("generation")) return "pv";
  if (s.includes("load") || s.includes("consumption")) return "load";
  if (s.includes("purchas")) return "imp";
  if (s.includes("sold") || s.includes("sell")) return "exp";
  if (s.includes("discharge")) return "dischg"; // must come before 'charge'
  if (s.includes("charge")) return "chg";
  return null;
}


export type Bucketed = (Record<string, number> | null)[];

/**
 * The plant /day feed mapped onto the 288 five-minute buckets of a day, RAW
 * (unscaled — see calibrateFeedScale). The inverters keep reporting to SunSynk while
 * our logger is asleep, so for recent days the cloud still has the missing minutes.
 * Returns null once the cloud has dropped the day (~1-2 weeks).
 *
 * The feed's Battery sign is already chart-convention (- = charging).
 */
export async function plantFeedForDay(acc: Account, plantId: number, day: string): Promise<Bucketed | null> {
  const data = await apiGet(`/plant/energy/${plantId}/day?lan=en&date=${day}&id=${plantId}`, acc);
  const byBucket: Bucketed = new Array(288).fill(null);
  for (const info of (data && data.infos) || []) {
    const k = plantSeriesKey(info.label);
    if (!k) continue;
    for (const r of info.records || []) {
      const parts = String(r.time || "").split(":").map(Number);
      const h = parts[0], mn = parts[1];
      if (!Number.isFinite(h)) continue;
      const bkt = h * 12 + Math.floor((mn || 0) / 5);
      if (bkt < 0 || bkt > 287 || r.value == null) continue;
      (byBucket[bkt] = byBucket[bkt] || {})[k] = num(r.value);
    }
  }
  return byBucket.some(Boolean) ? byBucket : null; // null = feed no longer has this day
}

// --- Feed scale calibration --------------------------------------------------
// SunSynk has served this parallel system's feed BOTH ways: battery & grid as a
// single inverter (~half), and as the full plant sum (since 2026-06-10). Don't
// hardcode either — derive per-series multipliers as the MEDIAN of real/feed across
// overlapping buckets. ~1 = full-sum, ~2 = halved.
const chartValOfAgg: Record<string, (r: any) => number> = {
  pv: (r) => Number(r.pv_w) || 0,
  batt: (r) => -(Number(r.batt_w) || 0), // chart convention, matching the feed
  grid: (r) => Number(r.grid_w) || 0,
  load: (r) => Number(r.load_w) || 0,
};
const clampScale = (v: number) => Math.min(2.5, Math.max(0.4, v));

export type FeedScale = { pv: number; batt: number; grid: number; load: number };

export function calibrateFeedScale(feed: Bucketed | null, realByBucket: any[]): FeedScale {
  const scale: Record<string, number> = {};
  const all: number[] = [];
  for (const k of Object.keys(chartValOfAgg)) {
    const ratios: number[] = [];
    for (let b = 0; b < 288; b++) {
      const r = realByBucket[b], e = feed && feed[b];
      if (!r || !e || e[k] == null) continue;
      const rv = chartValOfAgg[k](r), fv = e[k];
      if (Math.abs(rv) < 300 || Math.abs(fv) < 150) continue; // skip noise-level buckets
      if ((rv > 0) !== (fv > 0)) continue;                    // sign mismatch = transient
      ratios.push(rv / fv);
    }
    if (ratios.length >= 3) {
      ratios.sort((a, b) => a - b);
      scale[k] = clampScale(ratios[ratios.length >> 1]);
      all.push(...ratios);
    }
  }
  all.sort((a, b) => a - b);
  const overall = all.length >= 3 ? clampScale(all[all.length >> 1]) : 1;
  // grid borrows battery's scale when it has too few active buckets — they have
  // always moved together on this system
  if (scale.grid == null) scale.grid = scale.batt != null ? scale.batt : overall;
  for (const k of Object.keys(chartValOfAgg)) if (scale[k] == null) scale[k] = overall;
  return scale as FeedScale;
}

/** Build the 288-bucket array from q_day_agg rows (bucket = 5-min slot of day). */
export function bucketizeAgg(aggRows: any[]): any[] {
  const byBucket: any[] = new Array(288).fill(null);
  for (const r of aggRows) {
    const [h, mn] = String(r.hm).split(":").map(Number);
    byBucket[h * 12 + Math.floor(mn / 5)] = r;
  }
  return byBucket;
}

const round1 = (v: unknown) => Math.round((Number(v) || 0) * 10) / 10;

/**
 * Normalise a plant energy payload into kWh rows keyed by period.
 * `granularity` 'day' -> record times are YYYY-MM-DD; 'month' -> 1..12.
 *
 * gridMul scales grid import/export up to the full plant: SunSynk counts them only
 * on CT-bearing inverters (the slave has no CT), while PV and load are already
 * full-sum. Keeps these rows on the same convention as the live grid-today tile.
 */
export function rowsFromEnergy(infos: any[], granularity: "day" | "month", gridMul = 1) {
  const byKey: Record<string, Record<string, number>> = {};
  let times: string[] = [];
  for (const info of infos || []) {
    const key = energyKey(info.label);
    if (!key) continue;
    byKey[key] = {};
    for (const r of info.records || []) byKey[key][r.time] = num(r.value);
    if ((info.records || []).length > times.length) times = (info.records || []).map((r: any) => r.time);
  }
  return times.map((t) => ({
    time: t,
    granularity,
    pv: round1(byKey.pv?.[t] || 0),
    load: round1(byKey.load?.[t] || 0),
    imp: round1((byKey.imp?.[t] || 0) * gridMul),
    exp: round1((byKey.exp?.[t] || 0) * gridMul),
    chg: round1(byKey.chg?.[t] || 0),
    dischg: round1(byKey.dischg?.[t] || 0),
  }));
}

export async function fetchMonthRows(acc: Account, plantId: number, year: number, month1: number, gridMul = 1) {
  const date = `${year}-${String(month1).padStart(2, "0")}`;
  const data = await apiGet(`/plant/energy/${plantId}/month?lan=en&date=${date}&id=${plantId}`, acc);
  return rowsFromEnergy(data && data.infos, "day", gridMul);
}

export async function fetchYearRows(acc: Account, plantId: number, year: number, gridMul = 1) {
  const data = await apiGet(`/plant/energy/${plantId}/year?lan=en&date=${year}&id=${plantId}`, acc);
  return rowsFromEnergy(data && data.infos, "month", gridMul);
}
