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
// is first walked from that bookmark, per-inverter history only (the plant feed no
// longer holds those days). A day that answered is banked and the bookmark moves
// on, whatever it held (a night of null PV is not a failure). A day where an
// endpoint failed stops the walk without moving, so the next run retries it; the
// third failure gives the day up. No serials yet: nothing moves (the first poll
// stores them). Both dates clear when the bookmark passes the end. The link kicks
// this with ?plant=ID; the 6-hourly schedule finishes it.
//
// Temperatures (0045): every run also banks inverter AC/DC temperature from
// output/day — today first thing (a few calls the panel depends on), then, after
// gap recovery, a watermark walk (plant_config.temp_next) over past days, one call
// per inverter-day, inside the same time budget. History is the only source of
// these; nothing live reports them on the official key. A day's temps also ride
// along free whenever the spine fetch ran for it.
//
// ?plant=ID restricts a run to one plant and leaves the round-robin cursor alone.
import { type Account, db, markCursor, type PlantJob, plantsToPoll, rotateJobs } from "../_shared/sunsynk.ts";
import {
  bucketizeAgg,
  calibrateFeedScale,
  type FeedScale,
  plantFeedForDay,
} from "../_shared/plantfeed.ts";
import { dayStartEpoch, fetchInverterDay, fetchInverterTemps, plantSpine, type SpineRow, tempRows } from "../_shared/invhistory.ts";

const DEFAULT_WINDOW_DAYS = 14;
// Leave headroom under the 150 s free-tier wall clock; a partial sweep is fine
// because the next scheduled run picks up where this one stopped.
const TIME_BUDGET_MS = 110_000;

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

/** YYYY-MM-DD in the plant's zone. */
function localDate(tz: string, d = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(d);
}
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
      const feed = await plantFeedForDay(acc, plantId, today);
      if (feed) scale = calibrateFeedScale(feed, bucketizeAgg(agg));
    }
  } catch { /* keep the default */ }
  scaleCache.set(plantId, scale);
  return scale;
}

/** A spine row is usable only when every series the chart needs is present. */
const complete = (r: SpineRow | undefined): r is SpineRow =>
  !!r && r.pv_w != null && r.grid_w != null && r.load_w != null;

/** Per-inverter history for the plant's inverters, summed. Null if nothing came back. */
async function historySpine(acc: Account, plantId: number, tz: string, day: string, bank = true) {
  const sns = (((await rpc("plant_inverters", { p_plant: plantId })) ?? []) as any[]).map((r) => String(r.sn ?? r));
  if (!sns.length) return null;
  // One inverter at a time: 4 calls in flight, not 4 × inverters, for SunSynk's sake.
  const days = [];
  const lo = dayStartEpoch(tz, day);
  for (const sn of sns) {
    const d = await fetchInverterDay(acc, sn, day);
    days.push(d);
    if (bank) await bankTemps(plantId, sn, tempRows(d, lo)).catch((e) => console.error(`inverter_temp ${sn}:`, e));
  }
  const spine = plantSpine(days, lo);
  return spine.size ? { spine, days } : null;
}

/** Temperature rows into inverter_temp. Throws on a database error; callers decide. */
async function bankTemps(plantId: number, sn: string, rows: ReturnType<typeof tempRows>): Promise<number> {
  if (!rows.length) return 0;
  return Number(await rpc("q_insert_inverter_temp", { p_plant: plantId, p_sn: sn, p_rows: rows }) ?? 0);
}

/** Inverter serials the poller has stored for a plant. */
const plantSns = async (plantId: number) =>
  (((await rpc("plant_inverters", { p_plant: plantId })) ?? []) as any[]).map((r) => String(r.sn ?? r));

/** One day of temperatures for every inverter, one output/day call each. Throws on the first failure. */
async function fetchTempDay(job: PlantJob, sns: string[], day: string, started: number) {
  const lo = dayStartEpoch(job.timezone, day);
  let banked = 0;
  for (const sn of sns) {
    if (Date.now() - started > TIME_BUDGET_MS) throw new BudgetReached(day);
    banked += await bankTemps(job.plantId, sn, tempRows(await fetchInverterTemps(job.account, sn, day), lo));
  }
  return banked;
}
class BudgetReached extends Error { constructor(day: string) { super(`time budget reached at ${day}`); } }

/**
 * Today's temperatures, first thing in a plant's run: a handful of calls that must
 * not wait behind a long gap recovery, since the panel has no other source.
 */
async function temperatureToday(job: PlantJob, started: number) {
  const sns = await plantSns(job.plantId);
  if (!sns.length) return { banked: 0, reason: "no inverter serials stored yet" };
  try {
    return { banked: await fetchTempDay(job, sns, localDate(job.timezone), started), calls: sns.length };
  } catch (e) {
    return { banked: 0, error: String(e instanceof Error ? e.message : e) };
  }
}

const TEMP_MAX_TRIES = 3;
/**
 * The watermark walk, last in a plant's run: plant_config.temp_next up to
 * yesterday, one output/day call per inverter-day. A day advances the watermark
 * when every inverter answered and every insert committed; a day that fails is
 * retried next run and stepped past after TEMP_MAX_TRIES, so one dead serial
 * cannot stall the walk. Never walks further back than the cloud keeps (60 days).
 * Compare-and-set on the day, like the backfill bookmark: an overlapping run stops
 * rather than rewinding the other's bookmark.
 */
async function temperatureWalk(job: PlantJob, started: number) {
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
    let failed: string | null = null;
    try { banked += await fetchTempDay(job, sns, day, started); }
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
    if (failed) console.error(`temps ${plantId} ${day} given up after ${TEMP_MAX_TRIES} tries: ${failed}`);
    walked++; tries = 0;
  }
  return { banked, walked, walkedTo: day, stoppedEarly };
}

async function recoverDay(acc: Account, plantId: number, tz: string, day: string, historyOnly = false) {
  // Paged: PostgREST caps any one response at max_rows (1000) and a day nobody
  // logged is 1440 minutes. Before 0044 that silently left the last 440 unfilled.
  let gaps: number[] = [];
  for (let from = 0; ; ) {
    const { data, error } = await db.rpc("q_missing_minutes", { p_plant: plantId, p_day: day }).range(from, from + 999);
    if (error) throw new Error(`q_missing_minutes: ${error.message}`);
    if (!data?.length) break;
    gaps.push(...data.map((r: any) => Number(r.ts ?? r)));
    from += data.length;
  }
  if (!gaps.length) return { day, banked: 0, reason: "no gaps" };
  const wanted = gaps.length;

  // 1. per-inverter history
  let bankedHistory = 0;
  try {
    const h = await historySpine(acc, plantId, tz, day);
    const failed = h?.days.reduce((n, d) => n + d.failed, 0) ?? 0;
    if (historyOnly && (!h || failed > 0)) {
      return { day, banked: 0, missing: wanted, failed: true, reason: h ? `${failed} history endpoint(s) did not answer` : "no history came back" };
    }
    if (h) {
      const rows = gaps.map((ts) => ({ ts, row: h.spine.get(ts) }))
        .filter((x): x is { ts: number; row: SpineRow } => complete(x.row))
        .map(({ ts, row }) => ({ ts, ...row }));
      if (rows.length) {
        bankedHistory = Number(await rpc("q_insert_recovered", { p_plant: plantId, p_rows: rows, p_source: "invhistory" }) ?? 0);
        const filled = new Set(rows.map((r) => r.ts));
        gaps = gaps.filter((ts) => !filled.has(ts));
      }
    }
  } catch (e) {
    console.warn(`invhistory ${plantId} ${day}:`, e instanceof Error ? e.message : e);
  }
  if (!gaps.length) return { day, banked: bankedHistory, bankedHistory, missing: wanted };
  if (historyOnly) return { day, banked: bankedHistory, bankedHistory, missing: wanted, reason: "plant feed skipped (day older than the feed keeps)" };

  // 2. the plant feed for what is left
  const feed = await plantFeedForDay(acc, plantId, day);
  if (!feed) return { day, banked: bankedHistory, bankedHistory, missing: wanted, reason: "cloud no longer has this day" };

  // Calibrate against this day's own poller rows when there are enough of them
  // (>= 3 h); otherwise borrow the current scale.
  const pollerAgg = await rpc("q_day_agg", { p_plant: plantId, p_day: day, p_source: "poller" });
  const scale = (pollerAgg?.length ?? 0) >= 36
    ? calibrateFeedScale(feed, bucketizeAgg(pollerAgg))
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
  if (!rows.length) return { day, banked: bankedHistory, bankedHistory, missing: wanted, reason: "feed had no matching buckets" };

  const banked = await rpc("q_insert_recovered", { p_plant: plantId, p_rows: rows, p_source: "plantfeed" });

  return {
    day,
    banked: bankedHistory + Number(banked ?? 0),
    bankedHistory,
    bankedPlantFeed: Number(banked ?? 0),
    missing: wanted,
    scale: {
      pv: +scale.pv.toFixed(2), batt: +scale.batt.toFixed(2),
      grid: +scale.grid.toFixed(2), load: +scale.load.toFixed(2),
    },
    calibratedAgainst: (pollerAgg?.length ?? 0) >= 36 ? "own poller data" : "current scale",
  };
}

const BACKFILL_MAX_TRIES = 3;

/** Walk the backfill bookmark forward until it passes the end, a day fails, or the budget runs out. */
async function backfillPlant(job: PlantJob, started: number) {
  const { plantId, account, timezone: tz } = job;
  let day = job.backfillNext!;
  const until = job.backfillUntil ?? day;
  let tries = job.backfillTries;
  const results = [];
  let total = 0;
  let stoppedEarly: string | null = null;

  const sns = ((await rpc("plant_inverters", { p_plant: plantId })) ?? []) as any[];
  if (!sns.length) return { banked: 0, scanned: null, stoppedEarly: "no inverter serials stored yet; the first poll stores them", days: [] };

  for (; day <= until; day = addDays(tz, day, 1)) {
    if (Date.now() - started > TIME_BUDGET_MS) { stoppedEarly = `time budget reached at ${day}; next run continues from here`; break; }
    let r: { banked: number; failed?: boolean; reason?: string; error?: string; day: string };
    try {
      r = await recoverDay(account, plantId, tz, day, true);
    } catch (e) {
      r = { day, banked: 0, failed: true, error: String(e instanceof Error ? e.message : e) };
    }
    total += r.banked;
    if (r.banked > 0 || r.reason || r.error) results.push(r);

    const retry = !!r.failed && tries + 1 < BACKFILL_MAX_TRIES;
    const next = addDays(tz, day, 1);
    const done = next > until;
    const patch = retry ? { backfill_tries: tries + 1 }
      : done ? { backfill_next: null, backfill_until: null, backfill_tries: 0 }
      : { backfill_next: next, backfill_tries: 0 };
    // Compare-and-set on the day: an overlapping run (link kick vs schedule) must
    // not rewind or double-walk the bookmark. No row matched = the other run moved it.
    const { data: moved, error } = await db.from("plant_config").update(patch)
      .eq("plant_id", plantId).eq("backfill_next", day).select("plant_id");
    if (error) throw new Error(`backfill bookmark ${plantId}: ${error.message}`);
    if (!moved?.length) { stoppedEarly = `another run moved the bookmark at ${day}`; break; }
    if (retry) { stoppedEarly = `${day} failed (try ${tries + 1}); next run retries it`; break; }
    tries = 0;
  }
  return { banked: total, scanned: `${job.backfillNext} .. ${until}`, stoppedEarly, days: results };
}

async function recoverPlant(job: PlantJob, windowDays: number, started: number) {
  const { plantId, account, timezone: tz } = job;
  const tempsToday = await temperatureToday(job, started);
  const backfill = job.backfillNext ? await backfillPlant(job, started) : null;
  const stats = await rpc("q_stats", { p_plant: plantId });
  const row = Array.isArray(stats) ? stats[0] : stats;
  if (!row?.first_ts) return { plantId, banked: backfill?.banked ?? 0, backfill, temps: { today: tempsToday }, reason: "no history yet" };

  const today = localDate(tz);
  const firstLogged = localDate(tz, new Date(Number(row.first_ts) * 1000));
  let day = addDays(tz, today, -(windowDays - 1));
  if (day < firstLogged) day = firstLogged;

  const results = [];
  let total = 0;
  let stoppedEarly: string | null = null;

  for (; day <= today; day = addDays(tz, day, 1)) {
    if (Date.now() - started > TIME_BUDGET_MS) {
      stoppedEarly = `time budget reached at ${day}; remaining days will be picked up next run`;
      break;
    }
    try {
      const r = await recoverDay(account, plantId, tz, day);
      total += r.banked;
      if (r.banked > 0 || r.reason) results.push(r);
    } catch (e) {
      results.push({ day, banked: 0, error: String(e instanceof Error ? e.message : e) });
    }
  }

  // The walk goes last, so gap recovery keeps first call on the budget.
  let walk;
  try { walk = await temperatureWalk(job, started); }
  catch (e) { walk = { banked: 0, error: String(e instanceof Error ? e.message : e) }; }
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
async function dryRun(job: PlantJob, day: string) {
  const { plantId, account: acc, timezone: tz } = job;
  const h = await historySpine(acc, plantId, tz, day, false); // dry: writes nothing, temps included
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
        acTemp: d.acTemp?.length ?? 0, dcTemp: d.dcTemp?.length ?? 0 },
    })),
    spineMinutes: h.spine.size, pollerMinutes: (data ?? []).length, overlap,
    error: Object.fromEntries(series.map((k) => [k, { n: errs[k].length, median: q(errs[k], 0.5), p90: q(errs[k], 0.9) }])),
  };
}

Deno.serve(async (req) => {
  const started = Date.now();
  try {
    const url = new URL(req.url);
    const windowDays = Math.max(1, Math.min(120, Number(url.searchParams.get("days")) || DEFAULT_WINDOW_DAYS));
    // ?budget_ms= lets a test shrink the time budget; production never passes it.
    const budgetMs = Math.min(TIME_BUDGET_MS, Number(url.searchParams.get("budget_ms")) || TIME_BUDGET_MS);

    const only = Number(url.searchParams.get("plant")) || null;
    let jobs = await plantsToPoll();
    if (only && url.searchParams.get("dry") !== "1") jobs = jobs.filter((j) => j.plantId === only);
    if (!jobs.length) return json({ ok: true, banked: 0, reason: only ? `plant ${only} is not linked` : "no linked plants" });

    if (url.searchParams.get("dry") === "1") {
      const plantId = Number(url.searchParams.get("plant"));
      const day = url.searchParams.get("day") ?? "";
      const job = jobs.find((j) => j.plantId === plantId);
      if (!job || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return json({ error: "dry run needs plant=<linked id>&day=YYYY-MM-DD" }, 400);
      return json({ ok: true, dry: true, ...(await dryRun(job, day)), elapsedMs: Date.now() - started });
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
        plants.push({ plantId: job.plantId, banked: 0, error: String(e instanceof Error ? e.message : e) });
      }
      done++;
      if (!only) await markCursor("RECOVER_CURSOR", job.plantId);
    }

    return json({ ok: true, banked: total, windowDays, plants, elapsedMs: Date.now() - started });
  } catch (e) {
    console.error("recover failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
