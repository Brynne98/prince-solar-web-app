// `forecast` — pull solar irradiance from Open-Meteo and keep the fitted scale honest.
//
// Two modes, one function, because they share all the location/geometry plumbing:
//
//   (default)         fetch the next 3 days of hourly irradiance -> solar_forecast
//   ?mode=calibrate   backfill historical irradiance, then refit solar_forecast_cal.k
//                     against what the array actually produced at those hours
//
// Open-Meteo needs no key and no account, so unlike poll/recover this function holds
// no secrets — the only credential involved is the service-role key it is called with.
//
// The gotchas (azimuth convention, `_instant` vs hour-averaged, W/m² needing a fitted
// scale) are documented at length in migration 0012. Read that first if this looks
// like it is doing something arbitrary.
import { bootstrapPlantId, db } from "../_shared/sunsynk.ts";

const FORECAST_API = "https://api.open-meteo.com/v1/forecast";
const ARCHIVE_API = "https://archive-api.open-meteo.com/v1/archive";

const HOURLY = [
  "global_tilted_irradiance_instant",
  "shortwave_radiation_instant",
  "cloud_cover",
  "temperature_2m",
].join(",");

const TZ = "Africa/Johannesburg";
const FORECAST_DAYS = 4;        // today + 3; the RPC serves 3 and the extra covers rollover
const CAL_WINDOW_DAYS = 120;    // fit window. Our own history starts 2026-05-30.
const ARCHIVE_LAG_DAYS = 5;     // the archive trails real time by ~3 days; 5 is the margin
const BACKFILL_PAST_DAYS = 7;   // every fetch also re-pulls the last week, closing the
                                // gap between the archive window and today
const RETAIN_DAYS = 400;        // keep a year+ of irradiance so the fit always has samples

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

type Cfg = {
  lat: number; lon: number; tilt: number; azimuth: number;
  kwp: number; percentile: number; capMult: number;
};

/** PANEL_AZIMUTH is degrees from north; Open-Meteo wants 0 = south, +90 = west. */
const toOpenMeteoAzimuth = (fromNorth: number) =>
  ((((fromNorth - 180) % 360) + 540) % 360) - 180;

async function loadConfig(): Promise<Cfg> {
  const { data, error } = await db.from("app_config").select("key,value");
  if (error) throw new Error(`app_config: ${error.message}`);
  const m = new Map((data ?? []).map((r: any) => [r.key, Number(r.value)]));
  const need = (k: string) => {
    const v = m.get(k);
    if (v == null || !Number.isFinite(v)) throw new Error(`app_config.${k} is missing`);
    return v;
  };
  return {
    lat: need("LAT"), lon: need("LON"), tilt: need("PANEL_TILT"), azimuth: need("PANEL_AZIMUTH"),
    // Shared with the clear-sky calibration on purpose — same physical array, same
    // curtailment problem, so the same two knobs should tune both.
    kwp: need("SYSTEM_KWP"), percentile: need("SOLAR_CAL_PERCENTILE"), capMult: need("SOLAR_CAL_CAP_MULT"),
  };
}

type Row = {
  ts: number;
  gti_wm2: number;
  ghi_wm2: number | null;
  cloud_pct: number | null;
  temp_c: number | null;
};

/**
 * Open-Meteo returns wall-clock local times with no offset ("2026-08-14T09:00") plus a
 * separate utc_offset_seconds, so the epoch has to be reassembled rather than parsed.
 */
function toRows(payload: any): Row[] {
  const h = payload?.hourly;
  if (!h?.time?.length) return [];
  const offset = Number(payload.utc_offset_seconds ?? 0);
  const rows: Row[] = [];
  for (let i = 0; i < h.time.length; i++) {
    const gti = h.global_tilted_irradiance_instant?.[i];
    if (gti == null) continue;                       // gaps at the edge of the archive
    rows.push({
      ts: Math.round(Date.parse(`${h.time[i]}:00Z`) / 1000) - offset,
      gti_wm2: gti,
      ghi_wm2: h.shortwave_radiation_instant?.[i] ?? null,
      cloud_pct: h.cloud_cover?.[i] ?? null,
      temp_c: h.temperature_2m?.[i] ?? null,
    });
  }
  return rows;
}

async function fetchOpenMeteo(base: string, cfg: Cfg, extra: Record<string, string>): Promise<Row[]> {
  const url = new URL(base);
  url.searchParams.set("latitude", String(cfg.lat));
  url.searchParams.set("longitude", String(cfg.lon));
  url.searchParams.set("hourly", HOURLY);
  url.searchParams.set("tilt", String(Math.round(cfg.tilt)));
  url.searchParams.set("azimuth", String(Math.round(toOpenMeteoAzimuth(cfg.azimuth))));
  url.searchParams.set("timezone", TZ);
  for (const [k, v] of Object.entries(extra)) url.searchParams.set(k, v);

  const res = await fetch(url, { signal: AbortSignal.timeout(30_000) });
  const body = await res.json();
  if (!res.ok) throw new Error(`open-meteo ${res.status}: ${body?.reason ?? "unknown"}`);
  return toRows(body);
}

async function store(rows: Row[]) {
  if (!rows.length) return 0;
  // Archive rows overwrite forecast rows for the same hour, which is deliberate: for a
  // past hour the archive is the better number, and a better number is what the fit
  // wants. Nothing here tracks forecast-vs-outturn accuracy — refitting k on a rolling
  // window absorbs systematic error instead. See migration 0012.
  for (let i = 0; i < rows.length; i += 500) {
    const { error } = await db.from("solar_forecast").upsert(rows.slice(i, i + 500), { onConflict: "ts" });
    if (error) throw new Error(`solar_forecast upsert: ${error.message}`);
  }
  return rows.length;
}

const ymd = (d: Date) => new Intl.DateTimeFormat("en-CA", {
  timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit",
}).format(d);

const daysAgo = (n: number) => ymd(new Date(Date.now() - n * 86_400_000));

/** Median of a numeric array. Robust to the scatter a passing cloud puts in a single hour. */
function quantile(sorted: number[], q: number): number {
  if (!sorted.length) return NaN;
  const i = (sorted.length - 1) * q;
  const lo = Math.floor(i), hi = Math.ceil(i);
  return lo === hi ? sorted[lo] : sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo);
}

/**
 * Refit `k`, the watts this array makes per W/m² of plane-of-array irradiance.
 *
 * A percentile of the per-sample ratios, not a mean or a least-squares line, and the
 * reason is curtailment. When the battery is charging at its limit and the house is
 * quiet, the inverter simply stops harvesting what it cannot place — pv_w falls away
 * from irradiance for reasons that have nothing to do with the sky. Fitted against 67
 * days of this system's own history, the median ratio came out at 7.0 (implying a
 * 7.0 kW array from a 12.6 kWp one, which is nonsense) with quartiles spanning
 * 4.8-8.0. The upper percentile finds the un-curtailed envelope instead: 9.5.
 *
 * That the envelope is right is checkable independently. The existing clear-sky model,
 * fitted by a completely different route, puts midday mid-August at ~8.7 kW; this one
 * says ~9.2 kW at the brightest irradiance actually observed in the window. Two
 * unrelated paths landing within ~6% is the evidence that the azimuth conversion and
 * the instant-vs-averaged choice are both correct.
 *
 * The consequence for meaning: the forecast describes POTENTIAL generation — what the
 * sky offers this array — exactly as the dotted potential line on the chart does. On a
 * day with more sun than the house and battery can absorb, logged output will come in
 * under it. That is the correct quantity for the question the feature exists to answer
 * ("will tomorrow make enough that I needn't hold charge tonight?"), because
 * curtailment only ever happens when the answer is comfortably yes.
 */
async function calibrate(cfg: Cfg) {
  // Backfill the window first, so the fit has irradiance for days that predate this
  // feature. Re-runnable: every hour upserts by ts.
  const archive = await fetchOpenMeteo(ARCHIVE_API, cfg, {
    start_date: daysAgo(CAL_WINDOW_DAYS),
    end_date: daysAgo(ARCHIVE_LAG_DAYS),
  });
  const backfilled = await store(archive);

  // Irradiance is single-site; production to fit it against comes from the plant the
  // deployment was bootstrapped with (public.calibration_plant()).
  const plant = await bootstrapPlantId();
  if (plant == null) return { calibrated: false, backfilled, reason: "no plant linked yet" };
  const sorted = async (fn: string) => {
    const { data, error } = await db.rpc(fn, { p_plant: plant, p_days: CAL_WINDOW_DAYS });
    if (error) throw new Error(`${fn}: ${error.message}`);
    return (data ?? [])
      .map((r: any) => Number(r.ratio ?? Number(r.pv_w) / Number(r.gti)))
      .filter((r: number) => Number.isFinite(r) && r > 0)
      .sort((a: number, b: number) => a - b);
  };

  const ratios = await sorted("q_forecast_cal_samples");
  const dayRatios = await sorted("q_forecast_cal_days");

  // Below these the fit is noise dressed up as a number; leave the previous values (or
  // the nameplate fallback) in place rather than lurching to whatever a handful say.
  // Days are inherently scarcer than minutes, hence the much lower bar.
  if (ratios.length < 50 || dayRatios.length < 10) {
    return {
      calibrated: false, backfilled,
      reason: `only ${ratios.length} hour samples / ${dayRatios.length} whole days`,
    };
  }

  // Capped the same way solar_scale_w() caps its scale: a percentile is still an order
  // statistic, and one freak cloud-edge enhancement should not redefine the array.
  //
  // The two constants take DIFFERENT statistics, because they answer different questions:
  //
  //   k      the upper envelope, like solar_scale_w(). It scales the forecast curve on
  //          the chart, which should sit at what the array can actually reach at midday
  //          — otherwise real generation draws straight through the line above it.
  //
  //   k_day  the MEDIAN of un-curtailed days, i.e. a typical day's conversion rather
  //          than the best one. The envelope was tried first and read ~18% high against
  //          logged output (predicting 47.6 kWh on a day that made 32.7), because no
  //          real day sustains best-case conversion start to finish. This is the number
  //          on the card, and it should be what you'll probably get.
  const k = Math.min(quantile(ratios, cfg.percentile), cfg.kwp * cfg.capMult);
  const kDay = Math.min(quantile(dayRatios, 0.5), cfg.kwp * cfg.capMult);

  const { error: upErr } = await db.from("solar_forecast_cal").upsert({
    id: 1,
    k,
    k_day: kDay,
    samples: ratios.length,
    day_samples: dayRatios.length,
    window_days: CAL_WINDOW_DAYS,
    fit_lo: quantile(ratios, 0.25),
    fit_hi: quantile(ratios, 0.75),
    computed_at: new Date().toISOString(),
  }, { onConflict: "id" });
  if (upErr) throw new Error(`solar_forecast_cal upsert: ${upErr.message}`);

  return {
    calibrated: true, backfilled,
    k: Math.round(k * 100) / 100,
    kDay: Math.round(kDay * 100) / 100,
    samples: ratios.length,
    daySamples: dayRatios.length,
    spread: [quantile(ratios, 0.25), quantile(ratios, 0.75)].map((v) => Math.round(v * 100) / 100),
    // Sanity check for a human: at the 1000 W/m² reference irradiance this array makes
    // k kW. It should land somewhere near SYSTEM_KWP derated — wildly off means the
    // azimuth conversion or the instant/averaged distinction has gone wrong.
    impliedPeakKw: Math.round(k * 10) / 10,
  };
}

Deno.serve(async (req) => {
  const started = Date.now();
  try {
    const mode = new URL(req.url).searchParams.get("mode");
    const cfg = await loadConfig();

    if (mode === "calibrate") {
      const result = await calibrate(cfg);
      return json({ ok: true, mode: "calibrate", ...result, elapsedMs: Date.now() - started });
    }

    // past_days as well as forecast_days. The archive used by ?mode=calibrate trails
    // real time by ~5 days, and the forecast starts today, which left a four-day hole
    // between the two windows with no irradiance on file at all. Re-pulling the last
    // week on every run closes it permanently and costs one API call either way.
    const rows = await fetchOpenMeteo(FORECAST_API, cfg, {
      forecast_days: String(FORECAST_DAYS),
      past_days: String(BACKFILL_PAST_DAYS),
    });
    const stored = await store(rows);

    // Keep the table from growing without bound. Old irradiance past the fit window is
    // dead weight — but keep well over a year so a seasonal refit always has something.
    const cutoff = Math.floor(Date.now() / 1000) - RETAIN_DAYS * 86_400;
    await db.from("solar_forecast").delete().lt("ts", cutoff);

    return json({
      ok: true,
      mode: "forecast",
      hours: stored,
      azimuthSent: Math.round(toOpenMeteoAzimuth(cfg.azimuth)),
      elapsedMs: Date.now() - started,
    });
  } catch (e) {
    console.error("forecast failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
