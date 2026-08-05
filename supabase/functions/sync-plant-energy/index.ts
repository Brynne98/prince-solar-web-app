// `sync-plant-energy` — cache SunSynk's plant-level kWh totals into Postgres.
//
// These cover the plant's whole life, back to commissioning, so they cannot be
// derived from agg_minute (our own history starts 2026-05-30). Express fetched them
// live on every request; caching them here means the browser never triggers a
// SunSynk call and never needs a credential — which was the point of the port.
//
// Runs daily. The numbers only change for the current day/month, so a daily refresh
// is ample and cheap: ~9 API calls.
//   * monthly rows for every year with data (drives Lifetime / Monthly / Year)
//   * daily rows for the last N months, default 6 (drives Week, Month, Daily trends
//     and the Overview comparison arrows)
import { db } from "../_shared/sunsynk.ts";
import { fetchMonthRows, fetchYearRows, getPlantId } from "../_shared/plantfeed.ts";

const TZ = "Africa/Johannesburg";
const DEFAULT_DAILY_MONTHS = 6;
const MAX_YEARS_BACK = 10;
const TIME_BUDGET_MS = 110_000;

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

function localParts(d = new Date()) {
  const s = new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(d);
  const [y, m, day] = s.split("-").map(Number);
  return { y, m, day };
}

Deno.serve(async (req) => {
  const started = Date.now();
  try {
    const url = new URL(req.url);
    const dailyMonths = Math.max(1, Math.min(24, Number(url.searchParams.get("months")) || DEFAULT_DAILY_MONTHS));

    const plantId = await getPlantId();
    if (!plantId) return json({ error: "no plant id on this account" }, 502);

    // SunSynk counts grid import/export only on CT-bearing inverters (the slave has
    // no CT), while PV and load are already full-plant. Scale grid up so these rows
    // share the convention of the live grid tile and the arrows compare like for like.
    const { data: gm, error: gmErr } = await db.rpc("q_grid_feed_scale");
    if (gmErr) throw new Error(`q_grid_feed_scale: ${gmErr.message}`);
    const gridMul = Number(gm ?? 1) || 1;

    const now = localParts();
    const upserts: any[] = [];
    const synced = { years: [] as number[], months: [] as string[] };

    // --- monthly rows, walking back to the commission year ------------------
    // Data is contiguous from commissioning, so the first empty older year is the
    // floor. Stop there rather than burning calls on years that never existed.
    let foundAny = false;
    for (let yr = now.y; yr >= now.y - MAX_YEARS_BACK; yr--) {
      if (Date.now() - started > TIME_BUDGET_MS) break;
      const rows = await fetchYearRows(plantId, yr, gridMul);
      const nonEmpty = rows.filter((r) => r.pv > 0 || r.load > 0 || r.imp > 0 || r.exp > 0);
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
        });
      }
    }

    // --- daily rows for the recent window -----------------------------------
    for (let k = 0; k < dailyMonths; k++) {
      if (Date.now() - started > TIME_BUDGET_MS) break;
      const mAbs = now.y * 12 + (now.m - 1) - k;
      const yr = Math.floor(mAbs / 12);
      const mo = (mAbs % 12) + 1;
      const rows = await fetchMonthRows(plantId, yr, mo, gridMul);
      const nonEmpty = rows.filter((r) => /^\d{4}-\d{2}-\d{2}$/.test(String(r.time)));
      if (!nonEmpty.length) continue;
      synced.months.push(`${yr}-${String(mo).padStart(2, "0")}`);
      for (const r of nonEmpty) {
        upserts.push({
          plant_id: plantId, bucket: "day", period: r.time,
          pv_kwh: r.pv, load_kwh: r.load, imp_kwh: r.imp,
          exp_kwh: r.exp, chg_kwh: r.chg, dischg_kwh: r.dischg,
        });
      }
    }

    if (upserts.length) {
      const { error } = await db.from("plant_energy")
        .upsert(upserts, { onConflict: "plant_id,bucket,period" });
      if (error) throw new Error(`plant_energy upsert: ${error.message}`);
    }

    return json({
      ok: true,
      plantId,
      gridMul,
      rows: upserts.length,
      years: synced.years,
      months: synced.months,
      elapsedMs: Date.now() - started,
    });
  } catch (e) {
    console.error("sync-plant-energy failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
