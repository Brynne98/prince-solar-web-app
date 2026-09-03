// `recover` — bank logger-offline minutes from SunSynk's cloud, per plant.
//
// Ported from recoverDay()/recoverAllGaps() in server.js. The inverters report to
// SunSynk independently of our logger, so minutes we slept through still exist in
// the cloud — until it drops the day (~1-2 weeks). Those minutes get written to
// agg_minute tagged source='plantfeed':
//   * calibrated per-day against that day's own poller overlap (never hardcode the
//     feed's scale — it has changed under us before); thin days borrow today's
//   * ON CONFLICT DO NOTHING, so it can only fill holes, never overwrite a reading
//   * the live edge (last 10 min) is left to the poller
//   * fully reversible: delete from agg_minute where source = 'plantfeed'
//
// Runs on a schedule (the monolith swept every 6 h). Unlike the monolith it does NOT
// sweep all history: the cloud only holds recent days, so scanning 60+ days would
// burn API calls on days that can never return data. Default window is 14 days;
// override with ?days=N. Whatever is skipped is reported in the response.
//
// Multi-tenant: one pass per linked plant, read through the account that can see
// it. The time budget is shared across plants; whatever is left over is picked up
// next run.
import { type Account, db, type PlantJob, plantsToPoll } from "../_shared/sunsynk.ts";
import {
  bucketizeAgg,
  calibrateFeedScale,
  type FeedScale,
  plantFeedForDay,
} from "../_shared/plantfeed.ts";

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
const addDays = (tz: string, day: string, n: number) => {
  const [y, m, d] = day.split("-").map(Number);
  return localDate(tz, new Date(Date.UTC(y, m - 1, d + n, 12)));
};
/** Epoch of local midnight for a YYYY-MM-DD in the plant's zone. */
function dayStartEpoch(tz: string, day: string): number {
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

async function recoverDay(acc: Account, plantId: number, tz: string, day: string) {
  const missing = await rpc("q_missing_minutes", { p_plant: plantId, p_day: day });
  const gaps: number[] = (missing ?? []).map((r: any) => Number(r.ts ?? r));
  if (!gaps.length) return { day, banked: 0, reason: "no gaps" };

  const feed = await plantFeedForDay(acc, plantId, day);
  if (!feed) return { day, banked: 0, missing: gaps.length, reason: "cloud no longer has this day" };

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
  if (!rows.length) return { day, banked: 0, missing: gaps.length, reason: "feed had no matching buckets" };

  const banked = await rpc("q_insert_recovered", { p_plant: plantId, p_rows: rows });

  return {
    day,
    banked: Number(banked ?? 0),
    missing: gaps.length,
    scale: {
      pv: +scale.pv.toFixed(2), batt: +scale.batt.toFixed(2),
      grid: +scale.grid.toFixed(2), load: +scale.load.toFixed(2),
    },
    calibratedAgainst: (pollerAgg?.length ?? 0) >= 36 ? "own poller data" : "current scale",
  };
}

async function recoverPlant(job: PlantJob, windowDays: number, started: number) {
  const { plantId, account, timezone: tz } = job;
  const stats = await rpc("q_stats", { p_plant: plantId });
  const row = Array.isArray(stats) ? stats[0] : stats;
  if (!row?.first_ts) return { plantId, banked: 0, reason: "no history yet" };

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

  return {
    plantId,
    banked: total,
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

Deno.serve(async (req) => {
  const started = Date.now();
  try {
    const url = new URL(req.url);
    const windowDays = Math.max(1, Math.min(120, Number(url.searchParams.get("days")) || DEFAULT_WINDOW_DAYS));

    const jobs = await plantsToPoll();
    if (!jobs.length) return json({ ok: true, banked: 0, reason: "no linked plants" });

    const plants = [];
    let total = 0;
    for (const job of jobs) {
      if (Date.now() - started > TIME_BUDGET_MS) {
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
    }

    return json({ ok: true, banked: total, windowDays, plants, elapsedMs: Date.now() - started });
  } catch (e) {
    console.error("recover failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
