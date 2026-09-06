// Per-inverter minute history from SunSynk's cloud (API.md, "Endpoint survey —
// 5 Sep 2026"). The official host keeps 2+ months of it, at the datalogger's own
// cadence (master ~67 s, slave 5 min). Used by `recover` to rebuild the plant spine
// for minutes our logger slept through — per inverter, then summed, which is what
// the plant feed cannot do reliably (its scaling has changed under us before).
//
// What the five `…/day` endpoints give, and how the spine is built from them:
//   battery  soc              -> soc   (average over inverters with soc > 0)
//   grid     pac              -> grid  (sum; + import)
//   load     pac              -> load  (sum)
//   input    V-pv-n, I-pv-n   -> pv    (sum of V×I over strings, then inverters;
//                                        two calls, `column` takes one token)
//   battery power is NOT in history; it comes from the balance: batt = pv + grid − load
//   (+ charging), the same identity the poller uses for derived load (0033).
// Output is not needed for the spine and is not fetched.
//
// Five calls per inverter per day (date/edate do not span days).
import { type Account, apiGet } from "./sunsynk.ts";
import { num } from "./extract.ts";

/** A sample at `t` seconds after local midnight. */
export type Sample = { t: number; v: number };
export type SeriesMap = Map<string, Sample[]>;

/** Spine values for one minute; null where any inverter is missing that series. */
export type SpineRow = {
  pv_w: number | null; load_w: number | null; batt_w: number | null; grid_w: number | null; soc: number | null;
};

export const historyPaths = (sn: string, day: string) => {
  const q = `lan=en&date=${day}&edate=${day}`;
  return {
    battery: `/inverter/battery/${sn}/day?${q}&column=soc`,
    grid: `/inverter/grid/${sn}/day?${q}&column=pac`,
    load: `/inverter/load/${sn}/day?${q}&column=pac`,
    // `column` takes one token: vpv gives V-pv-n, ipv gives I-pv-n. Two calls.
    input_v: `/inverter/${sn}/input/day?${q}&column=vpv`,
    input_i: `/inverter/${sn}/input/day?${q}&column=ipv`,
  };
};

/** "2026-09-05 15:03:41" | "15:03:41" | "15:03" -> seconds after midnight, or null. */
export function secondsOfDay(time: unknown): number | null {
  const m = /(\d{1,2}):(\d{2})(?::(\d{2}))?\s*$/.exec(String(time ?? ""));
  if (!m) return null;
  const h = Number(m[1]), mn = Number(m[2]), s = Number(m[3] ?? 0);
  if (h > 23 || mn > 59 || s > 59) return null;
  return h * 3600 + mn * 60 + s;
}

/**
 * The feed's `infos[] {label, records[] {time, value}}` as label -> samples,
 * labels lower-cased, samples sorted by time. Tolerant of the shape the plant feed
 * uses (plantfeed.ts); anything unrecognised is skipped rather than thrown.
 */
export function parseSeries(data: any): SeriesMap {
  const out: SeriesMap = new Map();
  for (const info of (data && data.infos) || []) {
    const label = String(info?.label ?? "").toLowerCase().trim();
    if (!label) continue;
    const samples: Sample[] = [];
    for (const r of info.records || []) {
      const t = secondsOfDay(r?.time);
      if (t == null || r?.value == null || r.value === "") continue;
      samples.push({ t, v: num(r.value) });
    }
    samples.sort((a, b) => a.t - b.t);
    if (samples.length) out.set(label, samples);
  }
  return out;
}

/** First series whose label contains any of the needles. */
function seriesLike(m: SeriesMap, ...needles: string[]): Sample[] | null {
  for (const [label, s] of m) if (needles.some((n) => label.includes(n))) return s;
  return null;
}

/** PV power = Σ over strings of V×I, aligned on identical sample times. */
export function pvFromStrings(m: SeriesMap): Sample[] | null {
  const byT = new Map<number, number>();
  let any = false;
  for (const [label, volts] of m) {
    const vm = /^v-?pv-?(\d+)$/.exec(label);
    if (!vm) continue;
    const amps = m.get(`i-pv-${vm[1]}`) ?? m.get(`ipv${vm[1]}`) ?? m.get(`i-pv${vm[1]}`) ?? m.get(`ipv-${vm[1]}`);
    if (!amps) continue;
    const ampAt = new Map(amps.map((s) => [s.t, s.v]));
    for (const s of volts) {
      const i = ampAt.get(s.t);
      if (i == null) continue;
      byT.set(s.t, (byT.get(s.t) ?? 0) + s.v * i);
      any = true;
    }
  }
  if (!any) return null;
  return [...byT.entries()].map(([t, v]) => ({ t, v })).sort((a, b) => a.t - b.t);
}

export type InverterDay = {
  sn: string;
  pv: Sample[] | null; grid: Sample[] | null; load: Sample[] | null; soc: Sample[] | null;
  /** raw labels seen per endpoint, for the dry-run report */
  labels: Record<string, string[]>;
};

/** The four history endpoints for one inverter-day; a failed endpoint is null. */
export async function fetchInverterDay(acc: Account, sn: string, day: string): Promise<InverterDay> {
  const paths = historyPaths(sn, day);
  const keys = Object.keys(paths) as (keyof typeof paths)[];
  const settled = await Promise.allSettled(keys.map((k) => apiGet(paths[k], acc)));
  const parsed: Record<string, SeriesMap> = {};
  const labels: Record<string, string[]> = {};
  keys.forEach((k, i) => {
    parsed[k] = settled[i].status === "fulfilled" ? parseSeries((settled[i] as PromiseFulfilledResult<any>).value) : new Map();
    labels[k] = [...parsed[k].keys()];
  });
  const input: SeriesMap = new Map([...parsed.input_v, ...parsed.input_i]);
  return {
    sn,
    soc: seriesLike(parsed.battery, "soc"),
    grid: seriesLike(parsed.grid, "p-grid", "pac", "grid"),
    load: seriesLike(parsed.load, "p-load", "pac", "load"),
    pv: pvFromStrings(input),
    labels,
  };
}

/** Longest the last upload is trusted for: a 5-minute logger plus slack. */
export const HOLD_S = 360;

/**
 * Samples -> 1440 per-minute values. Minute m takes the last sample at or before
 * its end (m*60+59) that is no older than HOLD_S, else null.
 */
export function toMinutes(samples: Sample[] | null, holdS = HOLD_S): (number | null)[] {
  const out: (number | null)[] = new Array(1440).fill(null);
  if (!samples || !samples.length) return out;
  let j = 0;
  for (let m = 0; m < 1440; m++) {
    const end = m * 60 + 59;
    while (j + 1 < samples.length && samples[j + 1].t <= end) j++;
    const s = samples[j];
    if (s.t <= end && s.t > end - holdS) out[m] = s.v;
  }
  return out;
}

/**
 * The plant spine for a day: per minute, sums across inverters (null when any
 * inverter lacks that series that minute — a partial sum is worse than a hole),
 * SoC averaged over inverters reporting > 0, battery from the balance.
 * Keyed by epoch ts = dayStart + minute*60.
 */
export function plantSpine(days: InverterDay[], dayStart: number): Map<number, SpineRow> {
  const per = days.map((d) => ({
    pv: toMinutes(d.pv), grid: toMinutes(d.grid), load: toMinutes(d.load), soc: toMinutes(d.soc),
  }));
  const rows = new Map<number, SpineRow>();
  for (let m = 0; m < 1440; m++) {
    const sum = (k: "pv" | "grid" | "load") => {
      let s = 0;
      for (const p of per) { const v = p[k][m]; if (v == null) return null; s += v; }
      return s;
    };
    const pv = sum("pv"), grid = sum("grid"), load = sum("load");
    const socs = per.map((p) => p.soc[m]).filter((v): v is number => v != null && v > 0);
    const soc = socs.length ? socs.reduce((a, b) => a + b, 0) / socs.length : null;
    if (pv == null && grid == null && load == null && soc == null) continue;
    rows.set(dayStart + m * 60, {
      pv_w: pv == null ? null : Math.round(pv),
      grid_w: grid == null ? null : Math.round(grid),
      load_w: load == null ? null : Math.round(load),
      batt_w: pv == null || grid == null || load == null ? null : Math.round(pv + grid - load),
      soc: soc == null ? null : Math.round(soc),
    });
  }
  return rows;
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
