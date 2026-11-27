// Per-inverter minute history from SunSynk's cloud (API.md, "Endpoint survey —
// 5 Sep 2026"). The official host keeps 2+ months of it, at the datalogger's own
// cadence (master ~67 s, slave 5 min). Used by `recover` to rebuild the plant spine
// for minutes our logger slept through — per inverter, then summed, which is what
// the plant feed cannot do reliably (its scaling has changed under us before).
//
// What the `…/day` endpoints give, and how the spine is built from them:
//   battery  soc              -> soc   (average over inverters with soc > 0)
//   grid     pac, fac         -> grid  (sum; + import); F-grid banked per inverter (0046)
//   load     pac              -> load  (sum)
//   output   ppv  (P-pv)      -> pv    (total PV per inverter, one series; sum)
//            igbt_temp, dc_temp, vac1, fac -> AC TEMP / DC TEMP (°C), V-ac-1, F-ac:
//                                 banked per inverter in inverter_history (0045/0046);
//                                 nothing live reports the temperatures
//   input    V-pv-n, I-pv-n   -> pv    fallback only: sum of V×I over strings; two
//                                        calls, `column` takes one token. A 15-string
//                                        inverter uploading every ~67 s times out
//                                        SunSynk's backend here (sticky 504, 2026-09-13).
//   battery power is NOT in history; it comes from the balance: batt = pv + grid − load
//   (+ charging), the same identity the poller uses for derived load (0033).
//
// Four calls per inverter per day, six when P-pv is empty (date/edate do not span days).
//
// SOLAR-612: the web host's `/inverter/{sn}/day?params=<ids>` gives the same series in
// one call (ids from `/inverter/params`). Tried first; any failure or a missing spine
// series falls back to the four official calls above.
import type { DayClock } from "../../localtime.ts";
import { type Account, apiGet, webGet } from "./api.ts";
import { num } from "./extract.ts";

/** A sample at `t` seconds after local midnight. */
export type Sample = { t: number; v: number };
export type SeriesMap = Map<string, Sample[]>;

/** Spine values for one minute; null where any inverter is missing that series. */
export type { SpineRow } from "../types.ts";
import type { SpineRow } from "../types.ts";

export const historyPaths = (sn: string, day: string) => {
  const q = `lan=en&date=${day}&edate=${day}`;
  return {
    battery: `/inverter/battery/${sn}/day?${q}&column=soc`,
    grid: `/inverter/grid/${sn}/day?${q}&column=${GRID_COLUMNS}`,
    load: `/inverter/load/${sn}/day?${q}&column=pac`,
    // Total PV power as one series (P-pv). Found 2026-09-13: a 15-string inverter
    // uploading every ~67 s times out SunSynk's backend on the per-string
    // endpoints below (sticky HTTP 504 after 10 s), but answers this one.
    pv: `/inverter/${sn}/output/day?${q}&column=${OUTPUT_COLUMNS}`,
  };
};
/** `column` takes a comma list (survey 13 Sep 2026); the extra series ride along free. */
export const OUTPUT_COLUMNS = "ppv,dc_temp,igbt_temp,vac1,fac";
export const GRID_COLUMNS = "pac,fac";
/** The walk's own calls: the extra series without the spine. Two calls per inverter-day. */
export const extrasPaths = (sn: string, day: string) => {
  const q = `lan=en&date=${day}&edate=${day}`;
  return {
    output: `/inverter/${sn}/output/day?${q}&column=dc_temp,igbt_temp,vac1,fac`,
    grid: `/inverter/grid/${sn}/day?${q}&column=fac`,
  };
};
/** Per-string V and I, the fallback when P-pv is absent. `column` takes one token; two calls. */
export const stringPaths = (sn: string, day: string) => {
  const q = `lan=en&date=${day}&edate=${day}`;
  return {
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

/**
 * First series matching the needles, needle by needle: "p-grid" is tried against
 * every label before "grid" is, so F-grid (grid/day now returns pac,fac) can never
 * win over P-grid whatever order SunSynk lists them in.
 */
function seriesLike(m: SeriesMap, ...needles: string[]): Sample[] | null {
  for (const n of needles) for (const [label, s] of m) if (label.includes(n)) return s;
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
  /** history endpoints that were asked for and did not answer (0044: a backfill day banks only when 0) */
  failed: number;
  pv: Sample[] | null; grid: Sample[] | null; load: Sample[] | null; soc: Sample[] | null;
  /** extra series from the same output/day and grid/day calls; opportunistic, never counted in `failed` */
  acTemp: Sample[] | null; dcTemp: Sample[] | null; vac: Sample[] | null; fac: Sample[] | null; gridFac: Sample[] | null;
  /** raw labels seen per endpoint, for the dry-run report */
  labels: Record<string, string[]>;
};

/**
 * Web-host catalogue ids (`/inverter/params`, devType 2): 16 SOC, 23 P-grid, 24 F-grid,
 * 21 P-load, 518 P-pv, 77 AC TEMP, 67 V-ac-1, 60 F-ac. No DC TEMP: T-inv, t_pv, t_ctrl
 * and t_chg all read 0 on 538820 (20 Nov 2026), so DC stays with the official reads.
 */
export const WEB_DAY_PARAMS = "16,23,24,21,518,77,67,60";
export const webDayPath = (sn: string, day: string) =>
  `/inverter/${sn}/day?lan=en&date=${day}&edate=${day}&params=${WEB_DAY_PARAMS}`;

/** One inverter-day in one web-host call; null when it failed or any spine series is missing. */
export async function webInverterDay(acc: Account, sn: string, day: string): Promise<InverterDay | null> {
  const m = parseSeries(await webGet(webDayPath(sn, day), acc).catch(() => null));
  const soc = seriesLike(m, "soc"), grid = seriesLike(m, "p-grid"), load = seriesLike(m, "p-load"), pv = seriesLike(m, "p-pv");
  if (!soc || !grid || !load || !pv) return null;
  return {
    sn, failed: 0, soc, grid, load, pv,
    acTemp: seriesLike(m, "ac temp"), dcTemp: null,
    vac: seriesLike(m, "v-ac-1"), fac: seriesLike(m, "f-ac"), gridFac: seriesLike(m, "f-grid"),
    labels: { web: [...m.keys()] },
  };
}

/**
 * One inverter-day from history: the web host's single call first (SOLAR-612), else
 * SoC, grid, load and total PV in four official calls; the per-string V×I pair only
 * when P-pv came back empty. A failed endpoint is null. `web = false` skips the web host.
 */
export async function fetchInverterDay(acc: Account, sn: string, day: string, web = true): Promise<InverterDay> {
  const fromWeb = web ? await webInverterDay(acc, sn, day) : null;
  if (fromWeb) return fromWeb;
  const parsed: Record<string, SeriesMap> = {};
  const labels: Record<string, string[]> = {};
  const rejected = new Set<string>();
  const fetchAll = async (paths: Record<string, string>) => {
    const keys = Object.keys(paths);
    const settled = await Promise.allSettled(keys.map((k) => apiGet(paths[k], acc)));
    keys.forEach((k, i) => {
      const r = settled[i];
      if (r.status === "rejected") rejected.add(k);
      parsed[k] = r.status === "fulfilled" ? parseSeries(r.value) : new Map();
      labels[k] = [...parsed[k].keys()];
    });
  };
  await fetchAll(historyPaths(sn, day));
  // Power only: a bare "pv" would also match v-pv-1 / i-pv-1 / e-pv and skip the fallback.
  let pv = seriesLike(parsed.pv, "p-pv", "ppv");
  if (!pv) {
    await fetchAll(stringPaths(sn, day));
    pv = pvFromStrings(new Map([...parsed.input_v, ...parsed.input_i]));
  }
  // A rejection counts only if it cost a series: strings that filled in for a
  // rejected P-pv are fine; a rejected fallback with no P-pv is not.
  const failed = ["battery", "grid", "load"].filter((k) => rejected.has(k)).length
    + (pv == null && (rejected.has("pv") || rejected.has("input_v") || rejected.has("input_i")) ? 1 : 0);
  return {
    sn,
    failed,
    soc: seriesLike(parsed.battery, "soc"),
    grid: seriesLike(parsed.grid, "p-grid", "pac", "grid"),
    load: seriesLike(parsed.load, "p-load", "pac", "load"),
    pv,
    ...extrasOf(parsed.pv, parsed.grid),
    labels,
  };
}

export type Extras = { acTemp: Sample[] | null; dcTemp: Sample[] | null; vac: Sample[] | null; fac: Sample[] | null; gridFac: Sample[] | null };
/**
 * The extra series out of an output/day and a grid/day response. Labels (lower-cased):
 * "ac temp", "dc temp", "v-ac-1", "f-ac" on output; "f-grid" on grid. Needles are
 * exact: "ac" alone would hit V-ac-1, "fac" nothing.
 */
export const extrasOf = (out: SeriesMap | undefined, grid: SeriesMap | undefined): Extras => ({
  acTemp: out ? seriesLike(out, "ac temp") : null,
  dcTemp: out ? seriesLike(out, "dc temp") : null,
  vac: out ? seriesLike(out, "v-ac-1", "vac1") : null,
  fac: out ? seriesLike(out, "f-ac", "fac") : null,
  gridFac: grid ? seriesLike(grid, "f-grid", "fac") : null,
});

/**
 * The extra series only, two calls. Whatever answered is returned; `failed` names
 * the endpoints that did not, so the caller can bank the partial day and still
 * retry it.
 */
export async function fetchInverterExtras(acc: Account, sn: string, day: string, gridOnly = false): Promise<Extras & { failed: string[] }> {
  const p = extrasPaths(sn, day);
  // gridOnly: today's output/day is the poller's, every 10 minutes (bankTodayTemps).
  const [out, grid] = await Promise.allSettled([gridOnly ? Promise.resolve(null) : apiGet(p.output, acc), apiGet(p.grid, acc)]);
  const failed: string[] = [];
  const val = (r: PromiseSettledResult<any>, k: string) => {
    if (r.status === "fulfilled") return parseSeries(r.value);
    failed.push(`${k}: ${String(r.reason instanceof Error ? r.reason.message : r.reason)}`);
    return undefined;
  };
  return { ...extrasOf(gridOnly ? undefined : val(out, "output"), val(grid, "grid")), failed };
}

/** {ts, ac, dc, vac, fac, gfac} rows for q_insert_inverter_history, at the device's own sample times. */
export function historyRows(t: Extras, clock: DayClock) {
  const byT = new Map<number, Record<string, number>>();
  const put = (xs: Sample[] | null, k: string) => {
    for (const s of xs ?? []) {
      const row = byT.get(s.t) ?? { ts: clock.at(s.t) };
      row[k] = s.v;
      byT.set(s.t, row);
    }
  };
  put(t.acTemp, "ac"); put(t.dcTemp, "dc"); put(t.vac, "vac"); put(t.fac, "fac"); put(t.gridFac, "gfac");
  return [...byT.values()];
}

/** Longest the last upload is trusted for: a 5-minute logger plus slack. */
export const HOLD_S = 360;

/**
 * Samples (seconds since the day's start) -> per-minute values, `minutes` of them (1440, or
 * 1380 / 1500 on a day the clocks change). Minute m takes the last sample at or before its end
 * (m*60+59) that is no older than HOLD_S, else null.
 */
export function toMinutes(samples: Sample[] | null, holdS = HOLD_S, minutes = 1440): (number | null)[] {
  const out: (number | null)[] = new Array(minutes).fill(null);
  if (!samples || !samples.length) return out;
  let j = 0;
  for (let m = 0; m < minutes; m++) {
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
export function plantSpine(days: InverterDay[], clock: DayClock): Map<number, SpineRow> {
  const minutes = (clock.end - clock.start) / 60;
  // wall-clock sample times -> seconds since the day's start, right across a clock change (SOLAR-686 H20)
  const el = (xs: Sample[] | null) => xs && xs.map((s) => ({ t: clock.at(s.t) - clock.start, v: s.v }));
  const per = days.map((d) => ({
    pv: toMinutes(el(d.pv), HOLD_S, minutes), grid: toMinutes(el(d.grid), HOLD_S, minutes),
    load: toMinutes(el(d.load), HOLD_S, minutes), soc: toMinutes(el(d.soc), HOLD_S, minutes),
  }));
  const rows = new Map<number, SpineRow>();
  for (let m = 0; m < minutes; m++) {
    const sum = (k: "pv" | "grid" | "load") => {
      let s = 0;
      for (const p of per) { const v = p[k][m]; if (v == null) return null; s += v; }
      return s;
    };
    const pv = sum("pv"), grid = sum("grid"), load = sum("load");
    const socs = per.map((p) => p.soc[m]).filter((v): v is number => v != null && v > 0);
    const soc = socs.length ? socs.reduce((a, b) => a + b, 0) / socs.length : null;
    if (pv == null && grid == null && load == null && soc == null) continue;
    rows.set(clock.start + m * 60, {
      pv_w: pv == null ? null : Math.round(pv),
      grid_w: grid == null ? null : Math.round(grid),
      load_w: load == null ? null : Math.round(load),
      batt_w: pv == null || grid == null || load == null ? null : Math.round(pv + grid - load),
      soc: soc == null ? null : Math.round(soc),
    });
  }
  return rows;
}
