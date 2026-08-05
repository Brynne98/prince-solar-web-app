/**
 * Local history store (SQLite, via Node's built-in node:sqlite — no deps).
 *
 * The SunSynk cloud only retains a few days, so we bank every poll to disk to
 * build a real history. Design: "store raw, derive on read."
 *
 *   agg_minute  — coarse plant-aggregate spine (pv/load/batt/grid/soc) at 1/min.
 *                 Written ONLY by the live poller (`source = 'poller'`) — never
 *                 seed it from SunSynk's plant feed, which under-reports battery
 *                 & grid on parallel systems and corrupted history once already.
 *   readings    — rich PER-INVERTER typed columns (live only). The stuff you'd
 *                 actually trend: per-inverter pv/batt/grid/load + cumulative kWh.
 *   strings     — per-string PV (V/A/W) (live only).
 *   meta        — current inverter identity/firmware/capacity (overwritten/poll).
 *   gaps        — logger-offline windows (from_ts → to_ts), recorded at write
 *                 time when a poll lands > 90 s after the previous row. Powers
 *                 the day-chart "missing" badge and the integrity report.
 *   raw         — the FULL poll payload, gzipped, kept forever. The catch-all: any
 *                 field we didn't model is still here, promotable + backfillable
 *                 into a typed column later.
 *
 * Sign conventions (see DATA_PIPELINE.md §3.3): batt_w is + = CHARGING
 * (normalized at ingestion); grid_w is + = import.
 *
 * File lives at ./data/sunsynk.db (git-ignored). Override with DB_PATH in .env.
 */
const path = require('path');
const fs = require('fs');
const { DatabaseSync } = require('node:sqlite');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'data', 'sunsynk.db');
let db = null;

// Every typed per-inverter column, in bind order. Keep in sync with the CREATE.
const READING_COLS = [
  'ts', 'sn', 'status',
  'pv_w', 'pv_today_kwh', 'pv_total_kwh',
  'batt_power_w', 'batt_w', 'batt_soc', 'batt_voltage_v', 'batt_current_a', 'batt_temp_c',
  'batt_chg_today_kwh', 'batt_dischg_today_kwh', 'batt_chg_total_kwh', 'batt_dischg_total_kwh',
  'grid_w', 'grid_import_today_kwh', 'grid_export_today_kwh', 'grid_import_total_kwh', 'grid_export_total_kwh',
  'grid_freq_hz', 'grid_pf',
  'load_w', 'load_today_kwh', 'load_total_kwh', 'load_freq_hz',
  'output_w', 'output_volt_v', 'output_freq_hz',
];

function initDb() {
  if (db) return db;
  fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });
  db = new DatabaseSync(DB_PATH);
  db.exec('PRAGMA journal_mode = WAL;');
  db.exec(`
    CREATE TABLE IF NOT EXISTS agg_minute (
      ts INTEGER PRIMARY KEY,
      pv_w INTEGER, load_w INTEGER, batt_w INTEGER, grid_w INTEGER, soc INTEGER
    );
    CREATE TABLE IF NOT EXISTS readings (
      ts INTEGER, sn TEXT, status INTEGER,
      pv_w REAL, pv_today_kwh REAL, pv_total_kwh REAL,
      batt_power_w REAL, batt_w REAL, batt_soc REAL, batt_voltage_v REAL, batt_current_a REAL, batt_temp_c REAL,
      batt_chg_today_kwh REAL, batt_dischg_today_kwh REAL, batt_chg_total_kwh REAL, batt_dischg_total_kwh REAL,
      grid_w REAL, grid_import_today_kwh REAL, grid_export_today_kwh REAL, grid_import_total_kwh REAL, grid_export_total_kwh REAL,
      grid_freq_hz REAL, grid_pf REAL,
      load_w REAL, load_today_kwh REAL, load_total_kwh REAL, load_freq_hz REAL,
      output_w REAL, output_volt_v REAL, output_freq_hz REAL,
      PRIMARY KEY (ts, sn)
    );
    CREATE TABLE IF NOT EXISTS strings (
      ts INTEGER, sn TEXT, no INTEGER,
      volt_v REAL, current_a REAL, power_w REAL, today_kwh REAL,
      PRIMARY KEY (ts, sn, no)
    );
    CREATE TABLE IF NOT EXISTS meta (
      sn TEXT PRIMARY KEY, updated_ts INTEGER,
      alias TEXT, model TEXT, soft_ver TEXT, hmi_ver TEXT, gsn TEXT, comm_type TEXT,
      capacity_ah REAL, number_of_batteries INTEGER, plant_id INTEGER, plant_name TEXT
    );
    CREATE TABLE IF NOT EXISTS raw (
      ts INTEGER PRIMARY KEY, gz BLOB, bytes INTEGER
    );
    CREATE TABLE IF NOT EXISTS gaps (
      from_ts INTEGER PRIMARY KEY, to_ts INTEGER NOT NULL
    );
  `);

  // Migration: provenance column. Every surviving row is poller-sourced (the
  // backfill-seeded rows were purged in the §7 cleanup), so stamp them as such.
  const aggCols = db.prepare('PRAGMA table_info(agg_minute)').all().map((c) => c.name);
  if (!aggCols.includes('source')) {
    db.exec("ALTER TABLE agg_minute ADD COLUMN source TEXT;");
    db.exec("UPDATE agg_minute SET source = 'poller' WHERE source IS NULL;");
  }

  // One-time seed: derive historical gap events from the spine's timestamp jumps
  // so the gaps table also covers the era before write-time tracking existed.
  if (db.prepare('SELECT COUNT(*) AS n FROM gaps').get().n === 0) {
    const ts = db.prepare('SELECT ts FROM agg_minute ORDER BY ts').all().map((r) => r.ts);
    const ins = db.prepare('INSERT OR IGNORE INTO gaps (from_ts, to_ts) VALUES (?, ?)');
    for (let i = 1; i < ts.length; i++) {
      if (ts[i] - ts[i - 1] > 90) ins.run(ts[i - 1], ts[i]);
    }
  }
  return db;
}

const I = (v) => (v == null || v === '' || Number.isNaN(Number(v)) ? null : Math.round(Number(v)));
const R = (v) => (v == null || v === '' || Number.isNaN(Number(v)) ? null : Number(v));

// One live poll → write everything atomically.
function recordPoll(p) {
  initDb();
  const insAgg = db.prepare("INSERT OR IGNORE INTO agg_minute (ts,pv_w,load_w,batt_w,grid_w,soc,source) VALUES (?,?,?,?,?,?,'poller')");
  const insGap = db.prepare('INSERT OR IGNORE INTO gaps (from_ts, to_ts) VALUES (?, ?)');
  // Logger-offline detection: this poll landing > 90 s after the previous row
  // means the minutes between were never sampled — record the window durably.
  const prev = db.prepare('SELECT MAX(ts) AS t FROM agg_minute').get().t;
  const insRead = db.prepare(`INSERT OR REPLACE INTO readings (${READING_COLS.join(',')}) VALUES (${READING_COLS.map(() => '?').join(',')})`);
  const insStr = db.prepare('INSERT OR REPLACE INTO strings (ts,sn,no,volt_v,current_a,power_w,today_kwh) VALUES (?,?,?,?,?,?,?)');
  const upMeta = db.prepare('INSERT OR REPLACE INTO meta (sn,updated_ts,alias,model,soft_ver,hmi_ver,gsn,comm_type,capacity_ah,number_of_batteries,plant_id,plant_name) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)');
  const insRaw = db.prepare('INSERT OR REPLACE INTO raw (ts,gz,bytes) VALUES (?,?,?)');
  const bindReading = (r) => READING_COLS.map((c) => {
    if (c === 'ts') return p.ts;
    if (c === 'sn') return r.sn ?? null;
    if (c === 'status') return I(r.status);
    return R(r[c]);
  });

  db.exec('BEGIN');
  try {
    const a = p.agg;
    if (prev != null && p.ts - prev > 90) insGap.run(prev, p.ts);
    insAgg.run(p.ts, I(a.pv_w), I(a.load_w), I(a.batt_w), I(a.grid_w), I(a.soc));
    for (const r of p.readings) insRead.run(...bindReading(r));
    for (const s of p.strings) insStr.run(p.ts, s.sn, I(s.no), R(s.volt), R(s.current), R(s.power), R(s.today));
    for (const m of p.meta) {
      upMeta.run(m.sn, p.ts, m.alias ?? null, m.model ?? null, m.soft ?? null, m.hmi ?? null, m.gsn ?? null,
        m.comm ?? null, R(m.capacity_ah), I(m.number_of_batteries), I(m.plant_id), m.plant_name ?? null);
    }
    insRaw.run(p.ts, p.rawGz, I(p.rawBytes));
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
}

function getStats() {
  initDb();
  const a = db.prepare('SELECT COUNT(*) AS n, MIN(ts) AS mn, MAX(ts) AS mx FROM agg_minute').get();
  const days = db.prepare(
    `SELECT COUNT(*) AS d FROM (SELECT DISTINCT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') FROM agg_minute)`
  ).get();
  const rd = db.prepare('SELECT COUNT(*) AS n FROM readings').get();
  const raw = db.prepare('SELECT COUNT(*) AS n, COALESCE(SUM(bytes),0) AS src, COALESCE(SUM(LENGTH(gz)),0) AS gz FROM raw').get();
  return {
    aggRows: a.n,
    days: days.d,
    first: a.mn ? new Date(a.mn * 1000).toISOString() : null,
    last: a.mx ? new Date(a.mx * 1000).toISOString() : null,
    perInverterRows: rd.n,
    rawSnapshots: raw.n,
    rawBytesUncompressed: raw.src,
    rawBytesGzipped: raw.gz,
  };
}

// Loads above this (geyser, kettle, oven, aircon, EV…) are treated as deferrable
// "heavy" loads and excluded from the baseline, so spare solar reflects genuine
// headroom for running heavy things — not whatever heavy load happened to be on.
const HEAVY_LOAD_W = 1500;

// Average power profile by hour-of-day (local) over the last `days`. Powers the
// "peak solar / free solar" view:
//   pv_w           — solar generated (the free energy available)
//   baseline_load_w— typical non-heavy load (avg of sub-HEAVY_LOAD_W minutes)
//   spare_w        — pv − baseline = solar free to run heavy loads (NOT gamed by
//                    when a heavy load actually ran)
//   surplus_w      — pv − total load (for reference)
function byHour(days = 14) {
  initDb();
  const since = Math.floor(Date.now() / 1000) - days * 86400;
  // Only average days with FULL 24-hour data (all 24 hours present). This drops
  // commission/partial/outage days and today (still in progress), which would
  // otherwise skew the hourly means toward whatever portion of the day they cover.
  const rows = db.prepare(`
    WITH day_stats AS (
      SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS d,
             COUNT(DISTINCT CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER)) AS hours
      FROM agg_minute WHERE ts >= ? GROUP BY d
    )
    SELECT CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER) AS hour,
           ROUND(AVG(pv_w))   AS pv_w,
           ROUND(AVG(load_w)) AS load_w,
           ROUND(AVG(CASE WHEN load_w < ${HEAVY_LOAD_W} THEN load_w END)) AS baseline_load_w,
           ROUND(AVG(grid_w)) AS grid_w,
           ROUND(AVG(soc))    AS soc,
           COUNT(*)           AS samples
    FROM agg_minute
    WHERE ts >= ?
      AND strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') IN (SELECT d FROM day_stats WHERE hours >= 24)
    GROUP BY hour
    ORDER BY hour
  `).all(since, since);
  return rows.map((r) => {
    const baseline = r.baseline_load_w == null ? r.load_w : r.baseline_load_w;
    return {
      ...r,
      baseline_load_w: baseline,
      surplus_w: Math.round((r.pv_w || 0) - (r.load_w || 0)),
      spare_w: Math.round((r.pv_w || 0) - (baseline || 0)),
    };
  });
}

// Un-curtailed daytime samples (battery not yet full → panels run free, so actual
// PV ≈ potential) from complete days — calibrates the clear-sky scale (potential line).
function calSamples() {
  initDb();
  return db.prepare(`
    WITH day_stats AS (
      SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS d,
             COUNT(DISTINCT CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER)) AS hours
      FROM agg_minute GROUP BY d
    )
    SELECT ts, pv_w, soc FROM agg_minute
    WHERE pv_w > 800 AND soc < 85
      AND strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') IN (SELECT d FROM day_stats WHERE hours >= 24)
  `).all();
}

// Average power per day-SEGMENT over the last `days`, with the load split by source.
// Segments tile the day: 00–04 (deep night) · 04–06 (morning geysers) · 06–08 (dawn) ·
// 08–17 (daytime/solar) · 17–24 (evening).
//
// Per-minute load decomposition that ALWAYS reconciles to load (so it's correct even
// on historical grid-charge nights, where grid fed the battery, not the house):
//   solar→load = min(pv, load)                       (solar serves load first)
//   rem        = load − solar→load                   (what solar didn't cover)
//   batt→load  = (discharging) min(−batt, rem) else 0 (battery covers next)
//   grid→load  = rem − batt→load                      (grid covers the remainder)
// The three always sum to load; grid that charged the battery is correctly excluded.
function segmentPower(days = 7) {
  initDb();
  const since = Math.floor(Date.now() / 1000) - days * 86400;
  return db.prepare(`
    WITH d AS (
      SELECT CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER) AS h,
             COALESCE(load_w, 0) AS load, COALESCE(batt_w, 0) AS batt,
             MIN(COALESCE(pv_w, 0), COALESCE(load_w, 0)) AS s2l
      FROM agg_minute WHERE ts >= ?
    ),
    e AS (
      SELECT h, load, s2l,
             (load - s2l) AS rem,
             CASE WHEN batt < 0 THEN MIN(-batt, load - s2l) ELSE 0 END AS b2l
      FROM d
    )
    SELECT
      CASE WHEN h < 4 THEN 0 WHEN h < 6 THEN 1 WHEN h < 8 THEN 2 WHEN h < 17 THEN 3 ELSE 4 END AS seg,
      ROUND(AVG(load))         AS load_w,
      ROUND(AVG(s2l))          AS solar_w,
      ROUND(AVG(b2l))          AS batt_w,
      ROUND(AVG(rem - b2l))    AS grid_w,
      COUNT(*)                 AS mins
    FROM e GROUP BY seg ORDER BY seg
  `).all(since);
}

// (Removed 2026-06: eveningRows() / loadByDayHour() / samplesInHours() fed the
// overnight "battery at midnight" model + card, both removed — see server.js note.)

// Full day power series from the local spine (both inverters already summed),
// bucketed to ~5-min. Drives the day chart. `feed_n`/`row_n` expose per-bucket
// provenance so cloud-recovered buckets can render dotted. Pass `source` to
// restrict to one provenance (e.g. 'poller' for feed-scale calibration).
// Local date 'YYYY-MM-DD'.
function dayAgg(dateStr, source) {
  initDb();
  return db.prepare(`
    SELECT strftime('%H:%M', MIN(ts), 'unixepoch', 'localtime') AS hm,
           ROUND(AVG(pv_w))   AS pv_w,
           ROUND(AVG(load_w)) AS load_w,
           ROUND(AVG(batt_w)) AS batt_w,
           ROUND(AVG(grid_w)) AS grid_w,
           ROUND(AVG(soc))    AS soc,
           SUM(CASE WHEN source = 'plantfeed' THEN 1 ELSE 0 END) AS feed_n,
           COUNT(*)           AS row_n
    FROM agg_minute
    WHERE strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') = ?${source ? ' AND source = ?' : ''}
    GROUP BY strftime('%Y-%m-%d %H', ts, 'unixepoch', 'localtime'),
             CAST(strftime('%M', ts, 'unixepoch', 'localtime') AS INTEGER) / 5
    ORDER BY MIN(ts)
  `).all(...(source ? [dateStr, source] : [dateStr]));
}

// Minute timestamps of a local day that have NO row — the recovery work-list.
// Clamped to [first row ever logged, now − 10 min]: pre-logging days were never
// expected, and the live edge belongs to the poller (a cloud row landing on the
// current minute would block the poller's own INSERT).
function missingMinutes(dateStr) {
  initDb();
  const first = db.prepare('SELECT MIN(ts) AS t FROM agg_minute').get().t;
  if (!first) return [];
  const [y, mo, d] = dateStr.split('-').map(Number);
  const start = new Date(y, mo - 1, d).getTime() / 1000;
  const lo = Math.ceil(Math.max(start, first) / 60) * 60;
  const hi = Math.min(start + 86400, Math.floor(Date.now() / 1000) - 600);
  if (hi <= lo) return [];
  const have = new Set(
    db.prepare(`SELECT ts FROM agg_minute WHERE strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') = ?`)
      .all(dateStr).map((r) => r.ts)
  );
  const out = [];
  for (let ts = lo; ts < hi; ts += 60) if (!have.has(ts)) out.push(ts);
  return out;
}

// Bank cloud-recovered minutes. INSERT OR IGNORE: a poller row always wins —
// recovery can only fill holes, never overwrite a measurement.
function insertRecovered(rows) {
  initDb();
  const ins = db.prepare("INSERT OR IGNORE INTO agg_minute (ts,pv_w,load_w,batt_w,grid_w,soc,source) VALUES (?,?,?,?,?,?,'plantfeed')");
  let n = 0;
  db.exec('BEGIN');
  try {
    for (const r of rows) n += ins.run(r.ts, I(r.pv_w), I(r.load_w), I(r.batt_w), I(r.grid_w), I(r.soc)).changes;
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
  return n;
}

// Minutes of a local day that came from cloud recovery (for the chart badge).
function recoveredMinutes(dateStr) {
  initDb();
  return db.prepare(
    `SELECT COUNT(*) AS n FROM agg_minute WHERE source = 'plantfeed' AND strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') = ?`
  ).get(dateStr).n;
}

// Minutes of a local day the logger did NOT cover. The expected window is the
// day clipped to [first row ever logged, now] — so pre-logging days return null
// (nothing was expected) and today only counts elapsed time. Each agg_minute row
// covers one minute, so missing = window − rows.
function dayGapMinutes(dateStr) {
  initDb();
  const first = db.prepare('SELECT MIN(ts) AS t FROM agg_minute').get().t;
  if (!first) return null;
  const [y, mo, d] = dateStr.split('-').map(Number);
  const start = new Date(y, mo - 1, d).getTime() / 1000; // local midnight (host TZ = plant TZ)
  const lo = Math.max(start, first);
  const hi = Math.min(start + 86400, Math.floor(Date.now() / 1000));
  if (hi <= lo) return null;
  const n = db.prepare(
    `SELECT COUNT(*) AS n FROM agg_minute WHERE strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') = ?`
  ).get(dateStr).n;
  return Math.max(0, Math.round((hi - lo) / 60) - n);
}

// Most recent logger-offline windows (for the integrity CLI).
function recentGaps(limit = 15) {
  initDb();
  return db.prepare(
    'SELECT from_ts, to_ts, ROUND((to_ts - from_ts) / 60.0) AS minutes FROM gaps ORDER BY from_ts DESC LIMIT ?'
  ).all(limit);
}

// Physics integrity audit over the last `days` (DATA_PIPELINE.md §9):
//   §9A — per-row energy balance: in (pv + grid import + battery discharge) must
//         match out (load + grid export + battery charge) within conversion loss.
//         A clean day averages ~80–115 W residual; multi-hundred-W = sign error,
//         half-value, or unit bug.
//   §9B — batt_w > 0 (charging) must coincide with SOC rising on adjacent rows.
// Audits POLLER rows only — cloud-recovered minutes (source='plantfeed') are
// calibrated estimates at 5-min smoothing, not pipeline measurements; auditing
// them would flag feed noise, not our bugs.
// Plus a GRID CROSS-CHECK: the day's grid-import integral (all rows — what the
// Overview tile shows) vs the gap-immune counter estimate (master's lifetime
// etotalFrom delta × inverter/CT ratio; the daily counter resets AFTER midnight
// so it can't be used for day math). This re-validates the ~50/50 sharing
// assumption on every import day — only 2 such days existed when it was first
// validated (within 2%).
// Flags: 'residual' (day average beyond ±150 W), 'battery-sign' (≥3 violations
// and >5% of checked transitions — a few stragglers at charge/discharge
// flips are timing jitter, not corruption), 'grid-xcheck' (counter vs integral
// diverge >15% on a day with ≥1 kWh of import).
function integrityReport(days = 60) {
  initDb();
  const since = Math.floor(Date.now() / 1000) - days * 86400;
  const resid = db.prepare(`
    SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS d,
           COUNT(*) AS n,
           ROUND(AVG((COALESCE(pv_w,0) + MAX(COALESCE(grid_w,0),0) + MAX(-COALESCE(batt_w,0),0))
                   - (COALESCE(load_w,0) + MAX(-COALESCE(grid_w,0),0) + MAX(COALESCE(batt_w,0),0)))) AS avg_residual_w,
           ROUND(AVG(ABS((COALESCE(pv_w,0) + MAX(COALESCE(grid_w,0),0) + MAX(-COALESCE(batt_w,0),0))
                       - (COALESCE(load_w,0) + MAX(-COALESCE(grid_w,0),0) + MAX(COALESCE(batt_w,0),0))))) AS avg_abs_residual_w
    FROM agg_minute
    WHERE ts >= ? AND source = 'poller'
    GROUP BY d ORDER BY d
  `).all(since);
  const sign = db.prepare(`
    WITH seq AS (
      SELECT ts, batt_w, soc,
             LAG(ts)  OVER (ORDER BY ts) AS pts,
             LAG(soc) OVER (ORDER BY ts) AS psoc
      FROM agg_minute WHERE ts >= ? AND source = 'poller'
    )
    SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS d,
           SUM(CASE WHEN ABS(batt_w) > 300 AND soc <> psoc THEN 1 ELSE 0 END) AS checked,
           SUM(CASE WHEN ABS(batt_w) > 300 AND soc <> psoc
                     AND (CASE WHEN batt_w > 0 THEN 1 ELSE 0 END) <> (CASE WHEN soc > psoc THEN 1 ELSE 0 END)
               THEN 1 ELSE 0 END) AS violations
    FROM seq
    WHERE pts IS NOT NULL AND ts - pts <= 120 AND soc IS NOT NULL AND psoc IS NOT NULL
    GROUP BY d
  `).all(since);
  const signBy = Object.fromEntries(sign.map((r) => [r.d, r]));

  // Grid cross-check inputs. Integral over ALL rows (incl. recovered — that's
  // the series the tile integrates). Counter = end-of-day lifetime etotalFrom
  // per CT-bearing inverter (the slave's reads 0 and self-excludes), delta'd
  // against the previous day's close, scaled by inverters-per-CT.
  const gridInt = Object.fromEntries(db.prepare(`
    SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS d,
           SUM(MAX(COALESCE(grid_w,0),0)) / 60.0 / 1000 AS kwh
    FROM agg_minute WHERE ts >= ? GROUP BY d
  `).all(since).map((r) => [r.d, r.kwh]));
  const nInv = db.prepare('SELECT COUNT(DISTINCT sn) AS n FROM readings').get().n || 1;
  const nCt = db.prepare('SELECT COUNT(DISTINCT sn) AS n FROM readings WHERE grid_import_total_kwh > 0').get().n;
  const ctrRows = db.prepare(`
    SELECT d, eot FROM (
      SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS d,
             grid_import_total_kwh AS eot,
             ROW_NUMBER() OVER (PARTITION BY strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') ORDER BY ts DESC) AS rn
      FROM readings WHERE grid_import_total_kwh > 0
    ) WHERE rn = 1 ORDER BY d
  `).all();
  const gridCtr = {};
  for (let i = 1; i < ctrRows.length; i++) {
    gridCtr[ctrRows[i].d] = (ctrRows[i].eot - ctrRows[i - 1].eot) * (nCt ? nInv / nCt : 1);
  }

  // Battery-health metrics (longevity watch): daily temperature (heat is the #1
  // ageing factor for LFP) and hours spent ≥98% SOC (high SOC + heat is the bad
  // combo). Temp from the master BMS, junk-filtered (sensor emits -100 / 0 spikes).
  const tempBy = Object.fromEntries(db.prepare(`
    SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS d,
           ROUND(AVG(batt_temp_c), 1) AS avg_t, ROUND(MAX(batt_temp_c), 1) AS max_t
    FROM readings WHERE ts >= ? AND batt_temp_c > 0 AND batt_temp_c < 80
    GROUP BY d
  `).all(since).map((r) => [r.d, r]));
  const fullBy = Object.fromEntries(db.prepare(`
    SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS d,
           ROUND(SUM(CASE WHEN soc >= 98 THEN 1 ELSE 0 END) / 60.0, 1) AS hrs_full
    FROM agg_minute WHERE ts >= ? GROUP BY d
  `).all(since).map((r) => [r.d, r.hrs_full]));

  const out = resid.map((r) => {
    const s = signBy[r.d] || { checked: 0, violations: 0 };
    const flags = [];
    if (Math.abs(r.avg_residual_w) > 150) flags.push('residual');
    if (s.violations >= 3 && s.violations > 0.05 * Math.max(1, s.checked)) flags.push('battery-sign');
    const gInt = gridInt[r.d] ?? null;
    const gCtr = gridCtr[r.d] ?? null;
    if (gInt != null && gCtr != null && Math.max(gInt, gCtr) >= 1 && Math.abs(gCtr - gInt) / Math.max(gInt, gCtr) > 0.15) {
      flags.push('grid-xcheck');
    }
    const t = tempBy[r.d] || { avg_t: null, max_t: null };
    if (t.max_t != null && t.max_t > 35) flags.push('batt-heat'); // LFP ageing climbs above ~35°C
    return {
      date: r.d,
      minutes: r.n,
      gapMin: dayGapMinutes(r.d) ?? 0,
      recoveredMin: recoveredMinutes(r.d),
      avgResidualW: r.avg_residual_w,
      avgAbsResidualW: r.avg_abs_residual_w,
      signChecked: s.checked,
      signViolations: s.violations,
      gridIntegralKwh: gInt == null ? null : Math.round(gInt * 100) / 100,
      gridCounterKwh: gCtr == null ? null : Math.round(gCtr * 100) / 100,
      avgTempC: t.avg_t,
      maxTempC: t.max_t,
      hrsAtFull: fullBy[r.d] ?? 0,
      flags,
    };
  });
  return { days: out, flagged: out.filter((d) => d.flags.length).map((d) => d.date) };
}

// Live battery-health snapshot for the balance banner: current pack temperature
// and how long it has sat ≥98% SOC today (the two ageing signals to watch).
function batteryHealth() {
  initDb();
  const t = db.prepare(
    `SELECT batt_temp_c AS c FROM readings WHERE batt_temp_c > 0 AND batt_temp_c < 80 ORDER BY ts DESC LIMIT 1`
  ).get();
  const today = db.prepare(`
    SELECT ROUND(SUM(CASE WHEN soc >= 98 THEN 1 ELSE 0 END) / 60.0, 1) AS hrs_full,
           MAX(soc) AS peak_soc
    FROM agg_minute WHERE strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') = strftime('%Y-%m-%d', 'now', 'localtime')
  `).get();
  return {
    tempC: t ? t.c : null,
    hrsAtFullToday: today && today.hrs_full != null ? today.hrs_full : 0,
    peakSocToday: today ? today.peak_soc : null,
  };
}

// Battery BALANCE between the two inverters' banks — the desync signal. Per-timestamp
// SOC + voltage spread over the last `hours`, glitch-filtered (both banks must report a
// plausible 1–100% SOC, and a real spread can't jump >25% in a tick — that's a bad poll).
function bankBalance(hours = 72) {
  initDb();
  const since = Math.floor(Date.now() / 1000) - hours * 3600;
  return db.prepare(`
    SELECT ts,
           MAX(batt_soc) - MIN(batt_soc) AS socspread,
           MAX(batt_voltage_v) - MIN(batt_voltage_v) AS vspread,
           MAX(batt_soc) AS hi, MIN(batt_soc) AS lo
    FROM readings
    WHERE ts >= ? AND batt_soc IS NOT NULL AND batt_soc BETWEEN 1 AND 100
    GROUP BY ts
    HAVING COUNT(DISTINCT sn) = 2 AND (MAX(batt_soc) - MIN(batt_soc)) <= 25
    ORDER BY ts
  `).all(since);
}

// Latest per-inverter battery reading (for the live banner).
function latestBanks() {
  initDb();
  return db.prepare(`
    SELECT sn, batt_soc AS soc, batt_voltage_v AS voltage, batt_current_a AS current
    FROM readings WHERE ts = (SELECT MAX(ts) FROM readings WHERE batt_soc IS NOT NULL) ORDER BY sn
  `).all();
}

// SunSynk's plant energy feed counts grid import/export only on CT-bearing inverters
// (the slave has no grid CT → its import reads 0), so the feed is ~master-only. This
// returns inverters ÷ CT-bearing-inverters (= 2 here) to scale that feed up to the full
// plant — the same "2×master" estimate the integrity cross-check validated to ±2%.
function gridFeedScale() {
  initDb();
  const nInv = db.prepare('SELECT COUNT(DISTINCT sn) AS n FROM readings').get().n || 0;
  const nCt = db.prepare('SELECT COUNT(DISTINCT sn) AS n FROM readings WHERE grid_import_total_kwh > 0').get().n;
  return nInv > 0 && nCt > 0 ? nInv / nCt : 1;
}

module.exports = { initDb, recordPoll, getStats, byHour, calSamples, segmentPower, dayAgg, dayGapMinutes, missingMinutes, insertRecovered, recoveredMinutes, recentGaps, integrityReport, batteryHealth, gridFeedScale, bankBalance, latestBanks, DB_PATH };
