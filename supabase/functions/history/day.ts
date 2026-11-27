// A day step (SOLAR-686 H1, H11, H12): the minutes of a past day, or its extras (temperatures,
// volts, Hz). Moved from recover (recoverDay, fetchTempDay), unchanged in what it banks:
//   minutes: per-inverter history first (summed across the plant), then, for a day the plant feed
//            still holds, the feed for what is left, calibrated against that day's own reader
//            rows (thin days borrow today's scale). A complete row is never overwritten; the
//            last 10 minutes are the reader's (history.missing).
//   extras:  both endpoints per inverter; what answered is banked before a failed endpoint fails
//            the day; a day that lost only the grid endpoint retries that one alone.
import { db, rpc } from "../_shared/db.ts";
import { brandOf, type FeedScale, type SpineRow } from "../_shared/brands/index.ts";
import { dayClock, localDate } from "../_shared/localtime.ts";
import { noteError } from "../_shared/errors.ts";
import { jobs, type Result, type Step, write } from "./step.ts";

const H = (s: Step) => brandOf(s.login.brand).history;

/** Inverter serials stored for a plant (the first poll or the link stores them). */
const plantSns = async (plant: number) =>
  (((await rpc("plant_inverters", { p_plant: plant })) ?? []) as any[]).map((r) => String(r.sn ?? r));

/** A spine row is usable only when every series the chart needs is present. */
const complete = (r: SpineRow | undefined): r is SpineRow => !!r && r.pv_w != null && r.grid_w != null && r.load_w != null;

/** Today's feed scale for a plant, for days with too little of our own data to calibrate against. */
const scaleCache = new Map<number, FeedScale>();
async function currentFeedScale(s: Step): Promise<FeedScale> {
  const hit = scaleCache.get(s.plant);
  if (hit) return hit;
  let scale: FeedScale = { pv: 1, batt: 1, grid: 1, load: 1 };
  try {
    const today = localDate(s.timezone);
    const agg = await rpc("q_day_agg", { p_plant: s.plant, p_day: today, p_source: null });
    if ((agg?.length ?? 0) > 5) {
      const feed = await H(s).plantDay(s.login, s.vendor_plant_id, today);
      if (feed) scale = H(s).feedScale(feed, H(s).bucketsOf(agg));
    }
  } catch { /* keep the default */ }
  scaleCache.set(s.plant, scale);
  return scale;
}

async function missingMinutes(s: Step): Promise<number[]> {
  return ((await jobs<number[]>("missing", { id: s.id })) ?? []).map(Number);
}

export async function runMinutes(s: Step & { refused?: boolean }): Promise<Result> {
  const sns = await plantSns(s.plant);
  if (!sns.length) return { result: "wait", note: "no inverter serials stored yet; the first poll stores them" };
  let gaps = await missingMinutes(s);
  if (!gaps.length) return { result: "ok", note: "no gaps", banked: 0 };
  const wanted = gaps.length;
  const clock = dayClock(s.timezone, s.day!);

  // 1. per-inverter history, one inverter at a time (4 calls in flight, not 4 x inverters)
  let banked = 0, failed = 0;
  let days: any[] = [];
  try {
    for (const sn of sns) {
      const d = await H(s).inverterDay(s.login, sn, s.day!, true);
      days.push(d);
      failed += d.failed ?? 0;
    }
  } catch (e) {
    // a 429 is the login's: the step ends throttled and the login backs off (H7, H9)
    if (/rate-limited/.test(String(e instanceof Error ? e.message : e))) throw e;
    failed++;
    noteError("invhistory_failed", e, { plant: s.plant, hourly: true });
    if (!s.feed) return { result: "failed", note: `history: ${e instanceof Error ? e.message : e}` };
    // some inverters only: their sum is not the plant's, so no spine; the feed fills the day
    days = [];
  }
  // past the days the feed keeps, a day where an endpoint failed banks no minutes: a partial sum
  // (no SoC, say) would stand for good; it is tried again whole (as the old walk did)
  if (!s.feed && failed > 0) return { result: "failed", note: `${failed} history endpoint(s) did not answer` };
  // a write that fails (a lock held over 1 s, H21) fails the step, so it is tried again; it does
  // not fall through to the plant feed's coarser rows
  for (const [k, d] of days.entries()) {
    const rows = H(s).historyRows(d, clock);
    if (rows.length) await write(s, "extras", { sn: sns[k], rows });
    if (s.refused) return { result: "refused" };
  }
  const spine = H(s).plantSpine(days, clock);
  const spineRows = gaps.map((ts) => ({ ts, row: spine.get(ts) }))
    .filter((x): x is { ts: number; row: SpineRow } => complete(x.row))
    .map(({ ts, row }) => ({ ts, ...row }));
  if (spineRows.length) {
    banked += await write(s, "minutes", { rows: spineRows, source: "invhistory" });
    if (s.refused) return { result: "refused" };
    const filled = new Set(spineRows.map((r) => r.ts));
    gaps = gaps.filter((ts) => !filled.has(ts));
  }
  // every endpoint answered and none had minutes (before the plant ran, a dead logger): nothing
  // to try again
  const historyFailed = failed > 0;
  if (!gaps.length || (!historyFailed && !spine.size && !s.feed)) return { result: "ok", banked, note: spine.size ? undefined : "no history for this day" };
  // past the days the feed keeps: a day whose history did not answer is retried (SOLAR-525)
  if (!s.feed) return historyFailed ? { result: "failed", note: `${failed} history endpoint(s) did not answer`, banked } : { result: "ok", banked };

  // 2. the plant feed for what is left
  const feed = await H(s).plantDay(s.login, s.vendor_plant_id, s.day!);
  if (!feed) return historyFailed ? { result: "failed", note: "cloud no longer has this day", banked } : { result: "ok", banked };
  const pollerAgg = await rpc("q_day_agg", { p_plant: s.plant, p_day: s.day, p_source: "poller" });
  const scale = (pollerAgg?.length ?? 0) >= 36 ? H(s).feedScale(feed, H(s).bucketsOf(pollerAgg)) : await currentFeedScale(s);
  const rows: Record<string, number | null>[] = [];
  for (const ts of gaps) {
    // the feed's buckets are wall-clock five minutes (H20)
    const bkt = Math.floor(clock.wall(ts) / 300);
    const e = bkt >= 0 && bkt < feed.length ? feed[bkt] : null;
    if (!e) continue;
    rows.push({
      ts,
      pv_w: e.pv == null ? null : Math.round(e.pv * scale.pv),
      load_w: e.load == null ? null : Math.round(e.load * scale.load),
      // feed: - = charging  ->  stored: + = charging
      batt_w: e.batt == null ? null : Math.round(-e.batt * scale.batt),
      grid_w: e.grid == null ? null : Math.round(e.grid * scale.grid),
      soc: e.soc == null ? null : Math.round(e.soc),
    });
  }
  if (rows.length) banked += await write(s, "minutes", { rows, source: "plantfeed" });
  if (s.refused) return { result: "refused" };
  const left = wanted - banked;
  return historyFailed && left > 0
    ? { result: "failed", note: `${left} of ${wanted} minutes unfilled; history did not answer`, banked }
    : { result: "ok", banked };
}

export async function runExtras(s: Step & { refused?: boolean }): Promise<Result> {
  const sns = await plantSns(s.plant);
  if (!sns.length) return { result: "wait", note: "no inverter serials stored yet; the first poll stores them" };
  // a day that holds its temperatures already (an import after a switch back): nothing to fetch;
  // a retry always fetches, since a partial write can look whole
  if (!s.grid_only && !s.tries && await jobs<boolean>("has_extras", { plant: s.plant, day: s.day })) return { result: "ok", note: "held already", banked: 0 };
  const clock = dayClock(s.timezone, s.day!);
  let banked = 0;
  const failed: string[] = [];
  for (const sn of sns) {
    const x = await H(s).inverterExtras(s.login, sn, s.day!, s.grid_only);
    const rows = H(s).historyRows(x, clock);
    if (rows.length) banked += await write(s, "extras", { sn, rows });
    if (s.refused) return { result: "refused" };
    for (const f of x.failed ?? []) failed.push(`${sn} ${f}`);
  }
  if (!failed.length) return { result: "ok", banked };
  // only the grid endpoint failed: the next try asks that one alone (H12)
  const gridOnly = failed.every((f) => /grid/i.test(f));
  return { result: "failed", note: `${gridOnly ? "grid only: " : ""}${failed.join("; ")}`, banked };
}

/** ?dry=1: a whole day's spine against that day's reader rows, writing nothing (H22). */
export async function dryRun(s: Pick<Step, "plant" | "timezone" | "login" | "day">, web = true) {
  const sns = await plantSns(s.plant);
  const clock = dayClock(s.timezone, s.day!);
  const h = brandOf(s.login.brand).history;
  const days = [];
  for (const sn of sns) days.push(await h.inverterDay(s.login, sn, s.day!, web));
  const spine = h.plantSpine(days, clock);
  const { data, error } = await db.from("agg_minute").select("ts, pv_w, load_w, batt_w, grid_w, soc")
    .eq("plant_id", s.plant).eq("source", "poller").gte("ts", clock.start).lt("ts", clock.end);
  if (error) throw new Error(`agg_minute: ${error.message}`);
  return compare(spine, data ?? []);
}

/** Median and p90 of |history - reader| per series, and the minutes both have. */
export function compare(spine: Map<number, SpineRow>, reader: Record<string, any>[]) {
  const series = ["pv_w", "load_w", "batt_w", "grid_w", "soc"] as const;
  const errs: Record<string, number[]> = Object.fromEntries(series.map((k) => [k, []]));
  let overlap = 0;
  for (const a of reader) {
    const r = spine.get(Number(a.ts));
    if (!r) continue;
    overlap++;
    for (const k of series) {
      const x = (r as any)[k], y = a[k];
      if (x != null && y != null) errs[k].push(Math.abs(Number(x) - Number(y)));
    }
  }
  const q = (xs: number[], p: number) => {
    if (!xs.length) return null;
    const v = [...xs].sort((a, b) => a - b);
    return v[Math.min(v.length - 1, Math.floor(p * v.length))];
  };
  return {
    spineMinutes: spine.size, readerMinutes: reader.length, overlap,
    error: Object.fromEntries(series.map((k) => [k, { n: errs[k].length, median: q(errs[k], 0.5), p90: q(errs[k], 0.9) }])),
  };
}
