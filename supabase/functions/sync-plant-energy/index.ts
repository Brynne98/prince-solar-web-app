// `sync-plant-energy` — cache SunSynk's plant-level kWh totals into Postgres, per plant.
//
// These cover the plant's whole life, back to commissioning, so they cannot be
// derived from agg_minute (our own history starts 2026-05-30). Express fetched them
// live on every request; caching them here means the browser never triggers a
// SunSynk call and never needs a credential — which was the point of the port.
//
// Runs daily. The numbers only change for the current day/month, so a nightly run
// fetches this year and the last 2 months: 3 API calls per plant. On Sunday (plant's
// own time), and for one plant (?plant=, a new link or a history resync), it walks
// every year back to commissioning and the last 6 months: ~9 to 17 calls.
//   * monthly rows for every year with data (drives Lifetime / Monthly / Year)
//   * daily rows for the last N months, default 6 (drives Week, Month, Daily trends
//     and the Overview comparison arrows)
import { db, denyUnlessServer, markCursor, type PlantJob, plantsToPoll, rotateJobs, saveCallTally } from "../_shared/sunsynk.ts";
import { fetchMonthRows, fetchYearRows } from "../_shared/plantfeed.ts";
import { noteError, reportError, serve } from "../_shared/errors.ts";

const DEFAULT_DAILY_MONTHS = 6;
const NIGHTLY_MONTHS = 2;
const MAX_YEARS_BACK = 10;
const TIME_BUDGET_MS = 110_000;

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

function localParts(tz: string, d = new Date()) {
  const s = new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(d);
  const [y, m, day] = s.split("-").map(Number);
  return { y, m, day };
}

/** The grid multiplier from q_grid_feed_scale. A failed lookup gives 1 and the error,
 *  so the day rows are still written (SOLAR-522): on a new plant it times out while
 *  the minute backfill writes, and the next daily run puts the right figure back. */
export function gridScale(res: { data: unknown; error: { message: string } | null }) {
  if (res.error) return { gridMul: 1, gridErr: `q_grid_feed_scale: ${res.error.message}` };
  return { gridMul: Number(res.data ?? 1) || 1, gridErr: undefined };
}

const isSunday = (tz: string) =>
  new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "short" }).format(new Date()) === "Sun";

async function syncPlant(job: PlantJob, dailyMonths: number, started: number, full: boolean) {
  const { plantId, account, timezone: tz } = job;

  // SunSynk counts grid import/export only on CT-bearing inverters (the slave has
  // no CT), while PV and load are already full-plant. Scale grid up so these rows
  // share the convention of the live grid tile and the arrows compare like for like.
  const { gridMul, gridErr } = gridScale(await db.rpc("q_grid_feed_scale", { p_plant: plantId }));
  if (gridErr) noteError("grid_scale_failed", new Error(gridErr), { plant: plantId, hourly: true });

  const now = localParts(tz);
  // One stamp for the whole sweep. synced_at was absent from the upsert payload, so
  // ON CONFLICT never touched it and the column kept the value from the row's first
  // insert — the table could not say when it was last refreshed, only when it was
  // first written. Every row this run touches now carries the run's own time.
  const syncedAt = new Date().toISOString();
  const upserts: any[] = [];
  const synced = { years: [] as number[], months: [] as string[] };

  // --- daily rows for the recent window -----------------------------------
  // First, so a run cut by the time budget still has the recent days. A nightly run
  // takes this month and last; the weekly and first runs take all dailyMonths.
  const months = full ? dailyMonths : Math.min(dailyMonths, NIGHTLY_MONTHS);
  for (let k = 0; k < months; k++) {
    if (Date.now() - started > TIME_BUDGET_MS) break;
    const mAbs = now.y * 12 + (now.m - 1) - k;
    const yr = Math.floor(mAbs / 12);
    const mo = (mAbs % 12) + 1;
    const rows = await fetchMonthRows(account, plantId, yr, mo, gridMul);
    const nonEmpty = rows.filter((r) => /^\d{4}-\d{2}-\d{2}$/.test(String(r.time)));
    if (!nonEmpty.length) continue;
    synced.months.push(`${yr}-${String(mo).padStart(2, "0")}`);
    for (const r of nonEmpty) {
      upserts.push({
        plant_id: plantId, bucket: "day", period: r.time,
        pv_kwh: r.pv, load_kwh: r.load, imp_kwh: r.imp,
        exp_kwh: r.exp, chg_kwh: r.chg, dischg_kwh: r.dischg,
        synced_at: syncedAt,
      });
    }
  }

  // --- monthly rows, walking back to the commission year ------------------
  // Data is contiguous from commissioning, so the first empty older year is the
  // floor. Stop there rather than burning calls on years that never existed.
  let foundAny = false;
  // A nightly run takes only this year (and last year in January): older months no
  // longer change. The weekly and first runs walk back to commissioning (SOLAR-422).
  const lastYear = full ? now.y - MAX_YEARS_BACK : now.m === 1 ? now.y - 1 : now.y;
  for (let yr = now.y; yr >= lastYear; yr--) {
    if (Date.now() - started > TIME_BUDGET_MS) break;
    const rows = await fetchYearRows(account, plantId, yr, gridMul);
    // A series the vendor did not send is now null rather than 0. Reading it as 0
    // here keeps the original meaning of this test — "did anything positive come
    // back for this year" — since an absent series is not evidence the year exists.
    const nonEmpty = rows.filter((r) =>
      (r.pv ?? 0) > 0 || (r.load ?? 0) > 0 || (r.imp ?? 0) > 0 || (r.exp ?? 0) > 0);
    if (!nonEmpty.length) {
      if (foundAny) break;
      continue;
    }
    foundAny = true;
    synced.years.push(yr);
    for (const r of nonEmpty) {
      const mi = Number(r.time);
      if (!Number.isFinite(mi) || mi < 1 || mi > 12) continue;
      upserts.push({
        plant_id: plantId, bucket: "month",
        period: `${yr}-${String(mi).padStart(2, "0")}-01`,
        pv_kwh: r.pv, load_kwh: r.load, imp_kwh: r.imp,
        exp_kwh: r.exp, chg_kwh: r.chg, dischg_kwh: r.dischg,
        synced_at: syncedAt,
      });
    }
  }

  // Written only while the plant is still read (SOLAR-641, the poll check): the plant's version
  // from the job, checked under the plant's lock (q_upsert_plant_energy_v2, 0247). A plant
  // switched out or deleted while its totals were fetched writes nothing.
  if (upserts.length) {
    const { error } = await db.rpc("q_upsert_plant_energy_v2", { p_plant: plantId, p_version: job.version, p_rows: upserts });
    if (error?.code === "55000") return { plantId, gridMul, rows: 0, years: synced.years, months: synced.months, reason: "not read now" };
    if (error) throw new Error(`plant_energy upsert: ${error.message}`);
  }

  return { plantId, gridMul, ...(gridErr ? { gridErr } : {}), rows: upserts.length, years: synced.years, months: synced.months };
}

if (import.meta.main) serve("sync-plant-energy", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  const started = Date.now();
  try {
    const url = new URL(req.url);
    const dailyMonths = Math.max(1, Math.min(24, Number(url.searchParams.get("months")) || DEFAULT_DAILY_MONTHS));
    // ?budget_ms= lets a test shrink the time budget; production never passes it.
    const budgetMs = Math.min(TIME_BUDGET_MS, Number(url.searchParams.get("budget_ms")) || TIME_BUDGET_MS);

    // ?plant=ID (0044): one plant, cursor untouched — the link's bootstrap kick.
    const only = Number(url.searchParams.get("plant")) || null;
    let jobs = await plantsToPoll();
    if (only) jobs = jobs.filter((j) => j.plantId === only);
    if (!jobs.length) return json({ ok: true, rows: 0, reason: only ? `plant ${only} is not linked` : "no linked plants" });

    const plants = [];
    let rows = 0;
    // Round-robin from the plant the previous run finished on (READINESS P3).
    let done = 0;
    for (const job of only ? jobs : await rotateJobs(jobs, "SYNC_CURSOR")) {
      // Always make progress on at least one plant, however small the budget.
      if (done > 0 && Date.now() - started > budgetMs) {
        plants.push({ plantId: job.plantId, rows: 0, reason: "time budget reached before this plant" });
        continue;
      }
      try {
        const r = await syncPlant(job, dailyMonths, started, !!only || isSunday(job.timezone));
        rows += r.rows;
        plants.push(r);
      } catch (e) {
        // A 200 reply is all call_fn checks (0181); the note is what PostHog sees.
        noteError("sync_plant_failed", e, { plant: job.plantId, hourly: true });
        plants.push({ plantId: job.plantId, rows: 0, error: String(e instanceof Error ? e.message : e) });
      }
      done++;
      if (!only) await markCursor("SYNC_CURSOR", job.plantId);
    }

    return json({ ok: true, rows, plants, elapsedMs: Date.now() - started });
  } catch (e) {
    await reportError("sync-plant-energy", e);
    console.error("sync-plant-energy failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  } finally {
    await saveCallTally();
  }
});
