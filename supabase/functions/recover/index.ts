// `recover` — bank logger-offline minutes from SunSynk's cloud, per plant.
//
// Ported from recoverDay()/recoverAllGaps() in server.js. The inverters report to
// SunSynk independently of our logger, so minutes we slept through still exist in
// the cloud. Two sources, tried in order (0034):
//
//   1. per-inverter history (_shared/invhistory.ts): grid, load and SoC per inverter
//      straight from the device's own uploads, PV from string V×I, battery from the
//      balance; summed across the plant. No scaling to guess. 2+ months retained.
//      Written with source='invhistory'.
//   2. the plant feed, for whatever minutes history could not fill — until the
//      cloud drops the day (~1-2 weeks). Written with source='plantfeed':
//   * calibrated per-day against that day's own poller overlap (never hardcode the
//     feed's scale — it has changed under us before); thin days borrow today's
//   * ON CONFLICT DO NOTHING, so it can only fill holes, never overwrite a reading
//   * the live edge (last 10 min) is left to the poller
//   * fully reversible: delete from agg_minute where source = 'plantfeed'
//
// ?dry=1&plant=ID&day=YYYY-MM-DD builds the history spine for a whole day and
// reports its error against that day's poller rows, writing nothing — the way to
// check the parser against a new firmware or account before trusting it.
//
// Runs on a schedule (the monolith swept every 6 h). Unlike the monolith it does NOT
// sweep all history: the cloud only holds recent days, so scanning 60+ days would
// burn API calls on days that can never return data. Default window is 14 days;
// override with ?days=N. Whatever is skipped is reported in the response.
//
// Multi-tenant: one pass per linked plant, read through the account that can see
// it. The time budget is shared across plants; whatever is left over is picked up
// next run.
//
// Backfill (0044): a plant whose plant_config carries backfill_next..backfill_until
// is walked from backfill_until back to backfill_next, newest day first, after the
// recent window (SOLAR-171), per-inverter history only (the plant feed no longer
// holds those days). A day that answered is banked and the bookmark moves
// on, whatever it held (a night of null PV is not a failure). A day where an
// endpoint failed stops the walk without moving, so the next run retries it; the
// third failure gives the day up. No serials yet: nothing moves (the first poll
// stores them). Both dates clear when the bookmark passes the end. The link kicks
// this with ?plant=ID; the 6-hourly schedule finishes it.
//
// Inverter history (0045/0046): every run also banks the per-inverter extras —
// AC/DC temperature, AC terminal voltage and frequency, grid frequency — from
// output/day and grid/day: today first thing (a few calls the charts depend on),
// then, after gap recovery, a watermark walk (plant_config.temp_next) over past
// days, two calls per inverter-day, inside the same time budget. History is the
// only source of the temperatures; the same series also ride along free whenever
// the spine fetch ran for a day.
//
// ?plant=ID restricts a run to one plant and leaves the round-robin cursor alone.
//
// Writes are guarded (0246): each carries the plant's version from its job, and the
// database refuses it once the plant is switched out or deleted. A refused plant
// stops for this run.
//
// ?queue=1 (every minute since the billing switch-over, 0246): the history fetch
// queue. billing.history_take hands out at most one fetch per inverter-cloud login;
// each walks its days newest first, per-inverter history only, and reports every
// day to billing.history_step, which says when the next day may start (slowed
// fetches wait longer between days, never at the start) and drops a fetch whose
// plant was switched out. A 429 that outlasts apiGet's retries backs the login off.
import { db } from "../_shared/db.ts";
import { denyUnlessServer } from "../_shared/server.ts";
import { type Account, brandOf, DEFAULT_BRAND, type FeedScale, saveAllCalls, type SpineRow } from "../_shared/brands/index.ts";
import { markCursor, type PlantJob, plantsToPoll, rotateJobs, vendorOf } from "../_shared/plants.ts";
import { dayStartEpoch, localDate } from "../_shared/localtime.ts";
import { noteError, reportError, serve } from "../_shared/errors.ts";
const H = (acc: Account) => brandOf(acc.brand).history;

const DEFAULT_WINDOW_DAYS = 14;
// Leave headroom under the 150 s free-tier wall clock; a partial sweep is fine
// because the next scheduled run picks up where this one stopped.
const TIME_BUDGET_MS = 110_000;

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

// Calendar arithmetic needs no zone: formatting a UTC-noon instant in a UTC+12
// or later zone used to land on the NEXT day, skipping every other day.
const addDays = (_tz: string, day: string, n: number) => {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + n)).toISOString().slice(0, 10);
};
async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

// Each job and each queued fetch carries its own guard: the version its plant had when the
// work was handed out, and whether a write was refused since. Nothing is shared between
// requests, so a warm isolate running two at once never mixes them up.
import { type Guard, guardedWrite, newGuard, spineFailed } from "./guard.ts";
const guarded = (fn: "q_insert_recovered_v2" | "q_insert_inverter_history_v2", plantId: number, g: Guard, args: Record<string, unknown>) =>
  guardedWrite(rpc, fn, plantId, g, args);

/** Fallback scale for days with too little of our own data to calibrate against. */
const scaleCache = new Map<number, FeedScale>();
async function currentFeedScale(acc: Account, plantId: number, tz: string): Promise<FeedScale> {
  const hit = scaleCache.get(plantId);
  if (hit) return hit;
  let scale: FeedScale = { pv: 1, batt: 1, grid: 1, load: 1 }; // feed is full-sum as of 2026-06-10
  try {
    const today = localDate(tz);
    const agg = await rpc("q_day_agg", { p_plant: plantId, p_day: today, p_source: null });
    if ((agg?.length ?? 0) > 5) {
      const feed = await H(acc).plantDay(acc, await vendorOf(plantId), today);
      if (feed) scale = H(acc).feedScale(feed, H(acc).bucketsOf(agg));
    }
  } catch { /* keep the default */ }
  scaleCache.set(plantId, scale);
  return scale;
}

/** A spine row is usable only when every series the chart needs is present. */
const complete = (r: SpineRow | undefined): r is SpineRow =>
  !!r && r.pv_w != null && r.grid_w != null && r.load_w != null;

/** Per-inverter history for the plant's inverters, summed. Null if nothing came back. */
async function historySpine(acc: Account, plantId: number, tz: string, day: string, g: Guard | null, web = true) {
  const bank = g != null;
  const sns = (((await rpc("plant_inverters", { p_plant: plantId })) ?? []) as any[]).map((r) => String(r.sn ?? r));
  if (!sns.length) return null;
  // One inverter at a time: 4 calls in flight, not 4 × inverters, for the brand's sake.
  const days = [];
  const lo = dayStartEpoch(tz, day);
  for (const sn of sns) {
    const d = await H(acc).inverterDay(acc, sn, day, web);
    days.push(d);
    if (bank) await bankHistory(plantId, sn, H(acc).historyRows(d, lo), g!).catch((e) => {
      console.error(`inverter_history ${sn}:`, e);
      noteError("inverter_history_failed", e, { plant: plantId, hourly: true });
    });
  }
  const spine = H(acc).plantSpine(days, lo);
  return spine.size ? { spine, days } : null;
}

/** Sample rows into inverter_history. Throws on a database error; callers decide. */
async function bankHistory(plantId: number, sn: string, rows: Record<string, unknown>[], g: Guard): Promise<number> {
  if (!rows.length) return 0;
  return Number(await guarded("q_insert_inverter_history_v2", plantId, g, { p_sn: sn, p_rows: rows }) ?? 0);
}

/** Inverter serials the poller has stored for a plant. */
const plantSns = async (plantId: number) =>
  (((await rpc("plant_inverters", { p_plant: plantId })) ?? []) as any[]).map((r) => String(r.sn ?? r));

/**
 * One day of extras for every inverter, two calls each. What answered is banked
 * before a failed endpoint fails the day, so a retry loses nothing and a day
 * given up after TEMP_MAX_TRIES still holds whatever it had.
 */
async function fetchTempDay(job: PlantJob, g: Guard, sns: string[], day: string, started: number, gridOnly = false) {
  const lo = dayStartEpoch(job.timezone, day);
  let banked = 0;
  for (const sn of sns) {
    if (Date.now() - started > TIME_BUDGET_MS) throw new BudgetReached(day);
    const x = await H(job.account).inverterExtras(job.account, sn, day, gridOnly);
    banked += await bankHistory(job.plantId, sn, H(job.account).historyRows(x, lo), g);
    if (x.failed.length) throw new Error(`${sn} ${x.failed.join("; ")}`);
  }
  return banked;
}
class BudgetReached extends Error { constructor(day: string) { super(`time budget reached at ${day}`); } }

/**
 * Today's temperatures, first thing in a plant's run: a handful of calls that must
 * not wait behind a long gap recovery, since the panel has no other source.
 */
async function temperatureToday(job: PlantJob, g: Guard, started: number) {
  const sns = await plantSns(job.plantId);
  if (!sns.length) return { banked: 0, reason: "no inverter serials stored yet" };
  try {
    // Grid frequency only: the poller banks today's output/day every 10 minutes (SOLAR-422).
    return { banked: await fetchTempDay(job, g, sns, localDate(job.timezone), started, true), calls: sns.length };
  } catch (e) {
    noteError("temps_today_failed", e, { plant: job.plantId, hourly: true });
    return { banked: 0, error: String(e instanceof Error ? e.message : e) };
  }
}

const TEMP_MAX_TRIES = 3;
/**
 * The watermark walk, last in a plant's run: plant_config.temp_next up to
 * yesterday, two calls per inverter-day. A day advances the watermark
 * when every inverter answered and every insert committed; a day that fails is
 * retried next run and stepped past after TEMP_MAX_TRIES, so one dead serial
 * cannot stall the walk. Never walks further back than the cloud keeps (60 days).
 * Compare-and-set on the day, like the backfill bookmark: an overlapping run stops
 * rather than rewinding the other's bookmark.
 */
async function temperatureWalk(job: PlantJob, g: Guard, started: number) {
  const { plantId, timezone: tz } = job;
  const sns = await plantSns(plantId);
  if (!sns.length) return { banked: 0, reason: "no inverter serials stored yet" };
  const today = localDate(tz);
  const floor = addDays(tz, today, -60);
  let day = job.tempNext ?? floor;
  let tries = job.tempTries;
  let banked = 0, walked = 0;
  let stoppedEarly: string | null = null;

  if (day < floor) {
    // idle plant: skip the days the cloud has already dropped
    const { error } = await db.from("plant_config").update({ temp_next: floor, temp_tries: 0 }).eq("plant_id", plantId).eq("temp_next", day);
    if (error) throw new Error(`temp watermark ${plantId}: ${error.message}`);
    day = floor; tries = 0;
  }
  for (; day < today; day = addDays(tz, day, 1)) {
    if (Date.now() - started > TIME_BUDGET_MS) { stoppedEarly = `time budget reached at ${day}; next run continues from here`; break; }
    if (g.refused) { stoppedEarly = "plant switched out or deleted"; break; }
    let failed: string | null = null;
    try { banked += await fetchTempDay(job, g, sns, day, started); }
    catch (e) {
      if (e instanceof BudgetReached) { stoppedEarly = `${e.message}; next run continues from here`; break; }
      failed = String(e instanceof Error ? e.message : e);
    }
    const retry = failed != null && tries + 1 < TEMP_MAX_TRIES;
    const patch = retry ? { temp_tries: tries + 1 } : { temp_next: addDays(tz, day, 1), temp_tries: 0 };
    const { data: moved, error } = await db.from("plant_config").update(patch)
      .eq("plant_id", plantId).eq("temp_next", day).select("plant_id");
    if (error) throw new Error(`temp watermark ${plantId}: ${error.message}`);
    if (!moved?.length) { stoppedEarly = `another run moved the temperature watermark at ${day}`; break; }
    if (retry) { stoppedEarly = `${day} failed (try ${tries + 1}): ${failed}; next run retries it`; break; }
    if (failed) {
      console.error(`temps ${plantId} ${day} given up after ${TEMP_MAX_TRIES} tries: ${failed}`);
      noteError("temps_given_up", new Error(`temps ${plantId} ${day} given up after ${TEMP_MAX_TRIES} tries: ${failed}`), { plant: plantId, hourly: true });
    }
    walked++; tries = 0;
  }
  let pruned = 0;
  try { pruned = Number(await rpc("q_prune_inverter_history", { p_plant: plantId }) ?? 0); }
  catch (e) {
    console.error(`prune inverter_history ${plantId}:`, e);
    noteError("prune_failed", e, { plant: plantId, hourly: true });
  }
  return { banked, walked, walkedTo: day, stoppedEarly, pruned };
}

// wholeDay: every missing minute of the day (the history queue, 0246); else from the
// plant's first minute or its backfill floor (q_missing_minutes).
async function recoverDay(acc: Account, plantId: number, tz: string, day: string, g: Guard, historyOnly = false, wholeDay = false) {
  // Paged: PostgREST caps any one response at max_rows (1000) and a day nobody
  // logged is 1440 minutes. Before 0044 that silently left the last 440 unfilled.
  let gaps: number[] = [];
  const missingFn = wholeDay ? "q_missing_minutes_day" : "q_missing_minutes";
  for (let from = 0; ; ) {
    const { data, error } = await db.rpc(missingFn, { p_plant: plantId, p_day: day }).range(from, from + 999);
    if (error) throw new Error(`${missingFn}: ${error.message}`);
    if (!data?.length) break;
    gaps.push(...data.map((r: any) => Number(r.ts ?? r)));
    from += data.length;
  }
  if (!gaps.length) return { day, banked: 0, reason: "no gaps" };
  const wanted = gaps.length;

  // 1. per-inverter history. historyFailed: an endpoint did not answer, so the
  // minutes the plant feed can't fill may still be in the cloud (SOLAR-525).
  let bankedHistory = 0;
  let historyFailed = false;
  try {
    const h = await historySpine(acc, plantId, tz, day, g);
    const failed = h?.days.reduce((n, d) => n + d.failed, 0) ?? 0;
    historyFailed = !h || failed > 0;
    if (historyOnly && (!h || failed > 0)) {
      return { day, banked: 0, missing: wanted, failed: true, reason: h ? `${failed} history endpoint(s) did not answer` : "no history came back" };
    }
    if (h) {
      const rows = gaps.map((ts) => ({ ts, row: h.spine.get(ts) }))
        .filter((x): x is { ts: number; row: SpineRow } => complete(x.row))
        .map(({ ts, row }) => ({ ts, ...row }));
      if (rows.length) {
        bankedHistory = Number(await guarded("q_insert_recovered_v2", plantId, g, { p_rows: rows, p_source: "invhistory" }) ?? 0);
        const filled = new Set(rows.map((r) => r.ts));
        gaps = gaps.filter((ts) => !filled.has(ts));
      }
    }
  } catch (e) {
    historyFailed = true;
    console.warn(`invhistory ${plantId} ${day}:`, e instanceof Error ? e.message : e);
    noteError("invhistory_failed", e, { plant: plantId, hourly: true });
    // history only (the backfill walk, the queue): a day whose history write threw is retried
    if (historyOnly) return spineFailed(day, wanted, e);
  }
  if (!gaps.length) return { day, banked: bankedHistory, bankedHistory, missing: wanted };
  if (historyOnly) return { day, banked: bankedHistory, bankedHistory, missing: wanted, reason: "plant feed skipped (day older than the feed keeps)" };

  // 2. the plant feed for what is left
  const feed = await H(acc).plantDay(acc, await vendorOf(plantId), day);
  if (!feed) return { day, banked: bankedHistory, bankedHistory, missing: wanted, historyFailed, reason: "cloud no longer has this day" };

  // Calibrate against this day's own poller rows when there are enough of them
  // (>= 3 h); otherwise borrow the current scale.
  const pollerAgg = await rpc("q_day_agg", { p_plant: plantId, p_day: day, p_source: "poller" });
  const scale = (pollerAgg?.length ?? 0) >= 36
    ? H(acc).feedScale(feed, H(acc).bucketsOf(pollerAgg))
    : await currentFeedScale(acc, plantId, tz);

  const dayStart = dayStartEpoch(tz, day);
  const rows: Record<string, number | null>[] = [];
  for (const ts of gaps) {
    const bkt = Math.floor((ts - dayStart) / 300);
    const e = bkt >= 0 && bkt < 288 ? feed[bkt] : null;
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
  if (!rows.length) return { day, banked: bankedHistory, bankedHistory, missing: wanted, historyFailed, reason: "feed had no matching buckets" };

  const banked = await guarded("q_insert_recovered_v2", plantId, g, { p_rows: rows, p_source: "plantfeed" });

  return {
    day,
    banked: bankedHistory + Number(banked ?? 0),
    bankedHistory,
    bankedPlantFeed: Number(banked ?? 0),
    missing: wanted,
    historyFailed,
    scale: {
      pv: +scale.pv.toFixed(2), batt: +scale.batt.toFixed(2),
      grid: +scale.grid.toFixed(2), load: +scale.load.toFixed(2),
    },
    calibratedAgainst: (pollerAgg?.length ?? 0) >= 36 ? "own poller data" : "current scale",
  };
}

const BACKFILL_MAX_TRIES = 3;

/**
 * Walk the backfill bookmark back from its end, newest day first (SOLAR-171), until
 * it passes the start, a day fails, or the budget runs out. backfill_until is the
 * cursor; backfill_next stays put as the floor q_missing_minutes counts from.
 */
async function backfillPlant(job: PlantJob, g: Guard, started: number) {
  const { plantId, account, timezone: tz } = job;
  const floor = job.backfillNext!;
  let day = job.backfillUntil ?? floor;
  const from = day;
  let tries = job.backfillTries;
  const results = [];
  let total = 0;
  let stoppedEarly: string | null = null;

  const sns = ((await rpc("plant_inverters", { p_plant: plantId })) ?? []) as any[];
  if (!sns.length) return { banked: 0, scanned: null, stoppedEarly: "no inverter serials stored yet; the first poll stores them", days: [] };

  for (; day >= floor; day = addDays(tz, day, -1)) {
    if (Date.now() - started > TIME_BUDGET_MS) { stoppedEarly = `time budget reached at ${day}; next run continues from here`; break; }
    if (g.refused) { stoppedEarly = "plant switched out or deleted"; break; }
    let r: { banked: number; failed?: boolean; reason?: string; error?: string; day: string };
    try {
      r = await recoverDay(account, plantId, tz, day, g, true);
    } catch (e) {
      r = { day, banked: 0, failed: true, error: String(e instanceof Error ? e.message : e) };
    }
    total += r.banked;
    if (r.banked > 0 || r.reason || r.error) results.push(r);

    const retry = !!r.failed && tries + 1 < BACKFILL_MAX_TRIES;
    const next = addDays(tz, day, -1);
    const done = next < floor;
    const patch = retry ? { backfill_tries: tries + 1 }
      : done ? { backfill_next: null, backfill_until: null, backfill_tries: 0 }
      : { backfill_until: next, backfill_tries: 0 };
    // Compare-and-set on the day: an overlapping run (link kick vs schedule) must
    // not rewind or double-walk the bookmark. No row matched = the other run moved it.
    const { data: moved, error } = await db.from("plant_config").update(patch)
      .eq("plant_id", plantId).eq("backfill_until", day).select("plant_id");
    if (error) throw new Error(`backfill bookmark ${plantId}: ${error.message}`);
    if (!moved?.length) { stoppedEarly = `another run moved the bookmark at ${day}`; break; }
    if (retry) { stoppedEarly = `${day} failed (try ${tries + 1}); next run retries it`; break; }
    if (r.failed) {
      const why = `history ${plantId} ${day} given up after ${BACKFILL_MAX_TRIES} tries: ${r.error ?? r.reason}`;
      console.error(why);
      noteError("history_day_given_up", new Error(why), { plant: plantId, day });
    }
    tries = 0;
  }
  return { banked: total, scanned: `${from} back to ${floor}`, stoppedEarly, days: results };
}

async function recoverPlant(job: PlantJob, windowDays: number, started: number) {
  const { plantId, account, timezone: tz } = job;
  const g = newGuard(job.version);
  const tempsToday = await temperatureToday(job, g, started);
  const pending = !!job.backfillNext;
  const stats = await rpc("q_stats", { p_plant: plantId });
  const row = Array.isArray(stats) ? stats[0] : stats;
  if (!row?.first_ts && !pending) return { plantId, banked: 0, backfill: null, temps: { today: tempsToday }, reason: "no history yet" };

  // Today first, then back through the window (SOLAR-171): the days people look at
  // land before the old ones. While a first load runs the window ignores the first
  // stored minute, which is only the first poll's; the days before it are the point.
  const today = localDate(tz);
  const firstLogged = row?.first_ts ? localDate(tz, new Date(Number(row.first_ts) * 1000)) : today;
  let floor = addDays(tz, today, -(windowDays - 1));
  if (!pending && floor < firstLogged) floor = firstLogged;
  // A first load past midnight: the window moved on but the walk starts where it was set.
  if (pending && job.backfillUntil && addDays(tz, job.backfillUntil, 1) < floor) floor = addDays(tz, job.backfillUntil, 1);
  // Half the budget while the walk waits, so days that keep gaps cannot starve it.
  const windowBudget = pending ? TIME_BUDGET_MS / 2 : TIME_BUDGET_MS;

  const results = [];
  let total = 0;
  let stoppedEarly: string | null = null;

  // The window's oldest day gets its last try here: tomorrow it is outside. Minutes
  // still missing there because SunSynk did not answer are given up (SOLAR-525). Not
  // while a first load runs (every 2 min); the scheduled runs see the same day.
  const lastTry = addDays(tz, today, -(windowDays - 1));
  const giveUp = (day: string, why: string) => {
    if (day !== lastTry || day >= today || pending) return false;
    console.error(`gap repair ${plantId} ${day} given up: ${why}`);
    noteError("gap_day_given_up", new Error(`gap repair ${plantId} ${day} given up: ${why}`), { plant: plantId, day });
    return true;
  };
  for (let day = today; day >= floor; day = addDays(tz, day, -1)) {
    if (Date.now() - started > windowBudget) {
      stoppedEarly = `time budget reached at ${day}; remaining days will be picked up next run`;
      break;
    }
    if (g.refused) { stoppedEarly = "plant switched out or deleted"; break; }
    try {
      const r: any = await recoverDay(account, plantId, tz, day, g);
      total += r.banked;
      if (r.banked > 0 || r.reason) results.push(r);
      const left = (r.missing ?? 0) - r.banked;
      if (r.historyFailed && left > 0) giveUp(day, `${left} of ${r.missing} minutes unfilled; history did not answer${r.reason ? `, ${r.reason}` : ""}`);
    } catch (e) {
      const error = String(e instanceof Error ? e.message : e);
      results.push({ day, banked: 0, error });
      if (!giveUp(day, error)) noteError("recover_day_failed", e, { plant: plantId, day, hourly: true });
    }
  }

  // The first load's older days come after the window, newest first. A Free plant
  // past its week keeps 24 hours (0111): no first load, no walk over old days.
  const backfill = pending ? await backfillPlant(job, g, started) : null;

  // The walk goes last, so gap recovery keeps first call on the budget.
  let walk;
  try { walk = await temperatureWalk(job, g, started); }
  catch (e) {
    noteError("temps_walk_failed", e, { plant: plantId, hourly: true });
    walk = { banked: 0, error: String(e instanceof Error ? e.message : e) };
  }
  const temps = { today: tempsToday, walk };

  return {
    plantId,
    banked: total + (backfill?.banked ?? 0),
    backfill,
    temps,
    timezone: tz,
    scanned: `${addDays(tz, today, -(windowDays - 1))} .. ${today}`,
    // days older than the window are never scanned — the cloud has dropped them
    notScanned: firstLogged < addDays(tz, today, -(windowDays - 1))
      ? `${firstLogged} .. ${addDays(tz, today, -windowDays)} (outside window; cloud retains ~1-2 weeks)`
      : null,
    stoppedEarly,
    days: results,
  };
}

/** Median and p90 of |history − poller| per series over a day with poller rows. */
async function dryRun(job: PlantJob, day: string, web = true) {
  const { plantId, account: acc, timezone: tz } = job;
  const h = await historySpine(acc, plantId, tz, day, null, web); // dry: writes nothing, temps included
  if (!h) return { plantId, day, error: "no history came back" };
  const lo = dayStartEpoch(tz, day);
  const { data, error } = await db.from("agg_minute")
    .select("ts, pv_w, load_w, batt_w, grid_w, soc")
    .eq("plant_id", plantId).eq("source", "poller").gte("ts", lo).lt("ts", lo + 86400);
  if (error) throw new Error(`agg_minute: ${error.message}`);
  const series = ["pv_w", "load_w", "batt_w", "grid_w", "soc"] as const;
  const errs: Record<string, number[]> = Object.fromEntries(series.map((k) => [k, []]));
  let overlap = 0;
  for (const a of data ?? []) {
    const r = h.spine.get(Number(a.ts));
    if (!r) continue;
    overlap++;
    for (const k of series) {
      const x = (r as any)[k], y = (a as any)[k];
      if (x != null && y != null) errs[k].push(Math.abs(Number(x) - Number(y)));
    }
  }
  const q = (xs: number[], p: number) => {
    if (!xs.length) return null;
    const s = [...xs].sort((a, b) => a - b);
    return s[Math.min(s.length - 1, Math.floor(p * s.length))];
  };
  return {
    plantId, day, inverters: h.days.map((d) => ({
      sn: d.sn, labels: d.labels,
      samples: { pv: d.pv?.length ?? 0, grid: d.grid?.length ?? 0, load: d.load?.length ?? 0, soc: d.soc?.length ?? 0,
        acTemp: d.acTemp?.length ?? 0, dcTemp: d.dcTemp?.length ?? 0, vac: d.vac?.length ?? 0, fac: d.fac?.length ?? 0, gridFac: d.gridFac?.length ?? 0 },
    })),
    spineMinutes: h.spine.size, pollerMinutes: (data ?? []).length, overlap,
    error: Object.fromEntries(series.map((k) => [k, { n: errs[k].length, median: q(errs[k], 0.5), p90: q(errs[k], 0.9) }])),
  };
}

// ---------------------------------------------------------------------------
// The history fetch queue (?queue=1, 0246)
// ---------------------------------------------------------------------------
type Fetch = {
  id: number; claim: string; plant: number; account: string; day: string; floor: string; target_s: number;
  version: number; timezone: string; login: Account;
};
// Every minute from pg_cron: stop well inside the minute so runs do not pile up.
const QUEUE_BUDGET_MS = 45_000;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const step = (args: Record<string, unknown>) =>
  rpc("billing_jobs", { p_cmd: "history_step", p_args: args }) as Promise<{ go: boolean; day?: string; next_step_at?: string; status?: string }>;

// The claim lasts 90 s; a slow day (four inverters, retries) renews it every 30 s. Lost (it ran
// out and another run took the fetch): this run stops writing for it.
const RENEW_MS = 30_000;
async function runFetch(f: Fetch, started: number) {
  const acc: Account = { ...f.login, brand: f.login.brand ?? DEFAULT_BRAND };
  const g = newGuard(f.version);
  const claim = { id: f.id, claim: f.claim };
  let day = f.day, days = 0, banked = 0, lost = false;
  const renew = setInterval(() => {
    rpc("billing_jobs", { p_cmd: "history_renew", p_args: claim }).then((ok) => { if (ok !== true) { lost = true; g.refused = true; } })
      .catch(() => {});
  }, RENEW_MS);
  try {
    for (;;) {
      const before = H(acc).throttled(acc);
      let r: { banked: number; failed?: boolean };
      try { r = await recoverDay(acc, f.plant, f.timezone, day, g, true, true); }
      catch (e) { r = { banked: 0, failed: true }; noteError("history_fetch_day_failed", e, { plant: f.plant, hourly: true }); }
      if (lost) return { id: f.id, plant: f.plant, days, banked, stopped: "claim lost" };
      // switched or deleted mid-day: history_take drops it, or hands it out again on the new version
      if (g.refused) {
        await step({ ...claim, day: null });
        return { id: f.id, plant: f.plant, days, banked, stopped: "write refused" };
      }
      banked += r.banked; days++;
      const throttled = H(acc).throttled(acc) > before;
      const s = await step({ ...claim, day, failed: !!r.failed, throttled });
      if (!s.go) return { id: f.id, plant: f.plant, days, banked, status: s.status ?? null, throttled };
      const wait = Math.max(0, Date.parse(s.next_step_at!) - Date.now());
      if (Date.now() - started + wait > QUEUE_BUDGET_MS) {
        await step({ ...claim, day: null });     // free for the next run when its day is due
        return { id: f.id, plant: f.plant, days, banked, next: s.next_step_at };
      }
      if (wait) await sleep(wait);
      day = s.day!;
    }
  } finally {
    clearInterval(renew);
  }
}

async function runQueue(started: number) {
  const fetches = (await rpc("billing_jobs", { p_cmd: "history_take", p_args: {} }) ?? []) as Fetch[];
  // one fetch per login, so the logins run side by side
  const done = await Promise.allSettled(fetches.map((f) => runFetch(f, started)));
  return done.map((d, i) => d.status === "fulfilled" ? d.value : (() => {
    noteError("history_fetch_failed", d.reason, { plant: fetches[i].plant, hourly: true });
    return { id: fetches[i].id, plant: fetches[i].plant, error: String(d.reason instanceof Error ? d.reason.message : d.reason) };
  })());
}

serve("recover", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  const started = Date.now();
  try {
    const url = new URL(req.url);
    const windowDays = Math.max(1, Math.min(120, Number(url.searchParams.get("days")) || DEFAULT_WINDOW_DAYS));
    // ?budget_ms= lets a test shrink the time budget; production never passes it.
    const budgetMs = Math.min(TIME_BUDGET_MS, Number(url.searchParams.get("budget_ms")) || TIME_BUDGET_MS);

    if (url.searchParams.get("queue") === "1") return json({ ok: true, queue: await runQueue(started) });

    const only = Number(url.searchParams.get("plant")) || null;
    let jobs = await plantsToPoll();
    // plants the history queue is fetching are left to it (0246 fix 18)
    const fetching = new Set(((await rpc("billing_jobs", { p_cmd: "fetching", p_args: {} }).catch(() => [])) ?? []) as number[]);
    jobs = jobs.filter((j) => !fetching.has(j.plantId));
    if (only && url.searchParams.get("dry") !== "1") jobs = jobs.filter((j) => j.plantId === only);
    if (!jobs.length) return json({ ok: true, banked: 0, reason: only ? `plant ${only} is not linked` : "no linked plants" });

    if (url.searchParams.get("dry") === "1") {
      const plantId = Number(url.searchParams.get("plant"));
      const day = url.searchParams.get("day") ?? "";
      const job = jobs.find((j) => j.plantId === plantId);
      if (!job || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return json({ error: "dry run needs plant=<linked id>&day=YYYY-MM-DD" }, 400);
      const web = url.searchParams.get("source") !== "official"; // ?source=official skips the web host (SOLAR-612)
      return json({ ok: true, dry: true, ...(await dryRun(job, day, web)), elapsedMs: Date.now() - started });
    }

    const plants = [];
    let total = 0;
    // Start after the plant the previous run finished on, so a run that hits the
    // budget does not starve the same plants every time.
    let done = 0;
    for (const job of only ? jobs : await rotateJobs(jobs, "RECOVER_CURSOR")) {
      // Always make progress on at least one plant, however small the budget.
      if (done > 0 && Date.now() - started > budgetMs) {
        plants.push({ plantId: job.plantId, banked: 0, reason: "time budget reached before this plant" });
        continue;
      }
      try {
        const r = await recoverPlant(job, windowDays, started);
        total += r.banked;
        plants.push(r);
      } catch (e) {
        // A 200 reply is all call_fn checks (0181); the note is what PostHog sees.
        noteError("recover_plant_failed", e, { plant: job.plantId, hourly: true });
        plants.push({ plantId: job.plantId, banked: 0, error: String(e instanceof Error ? e.message : e) });
      }
      done++;
      if (!only) await markCursor("RECOVER_CURSOR", job.plantId);
    }

    return json({ ok: true, banked: total, windowDays, plants, elapsedMs: Date.now() - started });
  } catch (e) {
    await reportError("recover", e);
    console.error("recover failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  } finally {
    await saveAllCalls();
  }
});
