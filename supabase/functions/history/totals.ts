// A totals step (SOLAR-686 H2): the brand's kWh totals for a plant, moved from sync-plant-energy.
// These cover the plant's whole life, back to commissioning, so they cannot be derived from our
// minutes. Nightly: this year and the last 2 months (3 calls). In full (a link, a restart, the
// plant's Sunday, a mail that needs them): every year back to commissioning and 6 months of days.
//   * monthly rows for every year with data (Lifetime / Monthly / Year)
//   * daily rows for the recent months (Week, Month, Daily trends, the Overview arrows)
import { db } from "../_shared/db.ts";
import { brandOf } from "../_shared/brands/index.ts";
import { noteError } from "../_shared/errors.ts";
import { type Result, type Step, write } from "./step.ts";

const DAILY_MONTHS = 6;
const NIGHTLY_MONTHS = 2;
const MAX_YEARS_BACK = 10;

/** The grid multiplier from q_grid_feed_scale. A failed lookup gives 1 and the error, so the
 *  day rows are still written (SOLAR-522); the next run puts the right figure back. */
export function gridScale(res: { data: unknown; error: { message: string } | null }) {
  if (res.error) return { gridMul: 1, gridErr: `q_grid_feed_scale: ${res.error.message}` };
  return { gridMul: Number(res.data ?? 1) || 1, gridErr: undefined };
}

function localParts(tz: string, d = new Date()) {
  const s = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
  const [y, m, day] = s.split("-").map(Number);
  return { y, m, day };
}

export async function runTotals(s: Step & { refused?: boolean }): Promise<Result> {
  const h = brandOf(s.login.brand).history;
  // the brand counts grid only on CT-bearing inverters (the slave has none): scale it up so
  // these rows share the live grid tile's convention
  const { gridMul, gridErr } = gridScale(await db.rpc("q_grid_feed_scale", { p_plant: s.plant }));
  if (gridErr) noteError("grid_scale_failed", new Error(gridErr), { plant: s.plant, hourly: true });
  const now = localParts(s.timezone);
  const syncedAt = new Date().toISOString();
  const rows: any[] = [];

  const months = s.full ? DAILY_MONTHS : NIGHTLY_MONTHS;
  for (let k = 0; k < months; k++) {
    const mAbs = now.y * 12 + (now.m - 1) - k;
    const yr = Math.floor(mAbs / 12), mo = (mAbs % 12) + 1;
    for (const r of (await h.monthRows(s.login, s.vendor_plant_id, yr, mo, gridMul)).filter((r) => /^\d{4}-\d{2}-\d{2}$/.test(String(r.time)))) {
      rows.push({ plant_id: s.plant, bucket: "day", period: r.time, pv_kwh: r.pv, load_kwh: r.load, imp_kwh: r.imp,
        exp_kwh: r.exp, chg_kwh: r.chg, dischg_kwh: r.dischg, synced_at: syncedAt });
    }
  }
  // monthly rows back to the commission year: data is contiguous, so the first empty older year
  // is the floor. Nightly: only this year (and last year in January).
  let foundAny = false;
  const lastYear = s.full ? now.y - MAX_YEARS_BACK : now.m === 1 ? now.y - 1 : now.y;
  for (let yr = now.y; yr >= lastYear; yr--) {
    const got = (await h.yearRows(s.login, s.vendor_plant_id, yr, gridMul))
      .filter((r) => (r.pv ?? 0) > 0 || (r.load ?? 0) > 0 || (r.imp ?? 0) > 0 || (r.exp ?? 0) > 0);
    if (!got.length) { if (foundAny) break; continue; }
    foundAny = true;
    for (const r of got) {
      const mi = Number(r.time);
      if (!Number.isFinite(mi) || mi < 1 || mi > 12) continue;
      rows.push({ plant_id: s.plant, bucket: "month", period: `${yr}-${String(mi).padStart(2, "0")}-01`, pv_kwh: r.pv,
        load_kwh: r.load, imp_kwh: r.imp, exp_kwh: r.exp, chg_kwh: r.chg, dischg_kwh: r.dischg, synced_at: syncedAt });
    }
  }
  // written only while the plant is read and the claim holds (H8)
  const banked = rows.length ? await write(s, "totals", { rows }) : 0;
  return s.refused ? { result: "refused" } : { result: "ok", banked };
}
