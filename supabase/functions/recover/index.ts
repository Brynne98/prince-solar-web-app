// `recover` — bank logger-offline minutes from SunSynk's cloud.
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
import { db } from "../_shared/sunsynk.ts";
import {
  bucketizeAgg,
  calibrateFeedScale,
  type FeedScale,
  plantFeedForDay,
} from "../_shared/plantfeed.ts";

const TZ = "Africa/Johannesburg";
const DEFAULT_WINDOW_DAYS = 14;
// Leave headroom under the 150 s free-tier wall clock; a partial sweep is fine
// because the next scheduled run picks up where this one stopped.
const TIME_BUDGET_MS = 110_000;

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

/** YYYY-MM-DD in plant-local time. */
function localDate(d = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(d);
}
const addDays = (day: string, n: number) => {
  const [y, m, d] = day.split("-").map(Number);
  return localDate(new Date(Date.UTC(y, m - 1, d + n, 12)));
};

/** Fallback scale for days with too little of our own data to calibrate against. */
let currentScale: FeedScale | null = null;
async function currentFeedScale(): Promise<FeedScale> {
  if (currentScale) return currentScale;
  currentScale = { pv: 1, batt: 1, grid: 1, load: 1 }; // feed is full-sum as of 2026-06-10
  try {
    const today = localDate();
    const { data: agg } = await db.rpc("q_day_agg", { p_day: today, p_source: null });
    if ((agg?.length ?? 0) > 5) {
      const feed = await plantFeedForDay(today);
      if (feed) currentScale = calibrateFeedScale(feed, bucketizeAgg(agg));
    }
  } catch { /* keep the default */ }
  return currentScale;
}

async function recoverDay(day: string) {
  const { data: missing, error: mErr } = await db.rpc("q_missing_minutes", { p_day: day });
  if (mErr) throw new Error(`q_missing_minutes(${day}): ${mErr.message}`);
  const gaps: number[] = (missing ?? []).map((r: any) => Number(r.ts ?? r));
  if (!gaps.length) return { day, banked: 0, reason: "no gaps" };

  const feed = await plantFeedForDay(day);
  if (!feed) return { day, banked: 0, missing: gaps.length, reason: "cloud no longer has this day" };

  // Calibrate against this day's own poller rows when there are enough of them
  // (>= 3 h); otherwise borrow the current scale.
  const { data: pollerAgg } = await db.rpc("q_day_agg", { p_day: day, p_source: "poller" });
  const scale = (pollerAgg?.length ?? 0) >= 36
    ? calibrateFeedScale(feed, bucketizeAgg(pollerAgg))
    : await currentFeedScale();

  const dayStart = Date.parse(`${day}T00:00:00+02:00`) / 1000;
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

  const { data: banked, error } = await db.rpc("q_insert_recovered", { p_rows: rows });
  if (error) throw new Error(`q_insert_recovered(${day}): ${error.message}`);

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

Deno.serve(async (req) => {
  const started = Date.now();
  try {
    const url = new URL(req.url);
    const windowDays = Math.max(1, Math.min(120, Number(url.searchParams.get("days")) || DEFAULT_WINDOW_DAYS));

    const { data: stats, error: sErr } = await db.rpc("q_stats");
    if (sErr) throw new Error(`q_stats: ${sErr.message}`);
    const row = Array.isArray(stats) ? stats[0] : stats;
    if (!row?.first_ts) return json({ ok: true, banked: 0, reason: "no history yet" });

    const today = localDate();
    const firstLogged = localDate(new Date(Number(row.first_ts) * 1000));
    let day = addDays(today, -(windowDays - 1));
    if (day < firstLogged) day = firstLogged;

    const results = [];
    let total = 0;
    let stoppedEarly: string | null = null;

    for (; day <= today; day = addDays(day, 1)) {
      if (Date.now() - started > TIME_BUDGET_MS) {
        stoppedEarly = `time budget reached at ${day}; remaining days will be picked up next run`;
        break;
      }
      try {
        const r = await recoverDay(day);
        total += r.banked;
        if (r.banked > 0 || r.reason) results.push(r);
      } catch (e) {
        results.push({ day, banked: 0, error: String(e instanceof Error ? e.message : e) });
      }
    }

    return json({
      ok: true,
      banked: total,
      windowDays,
      scanned: `${addDays(today, -(windowDays - 1))} .. ${today}`,
      // days older than the window are never scanned — the cloud has dropped them
      notScanned: firstLogged < addDays(today, -(windowDays - 1))
        ? `${firstLogged} .. ${addDays(today, -windowDays)} (outside window; cloud retains ~1-2 weeks)`
        : null,
      stoppedEarly,
      days: results,
      elapsedMs: Date.now() - started,
    });
  } catch (e) {
    console.error("recover failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
