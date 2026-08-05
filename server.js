/**
 * SunSynk Connect dashboard - backend
 *
 * Logs into the SunSynk Connect cloud API with your account credentials,
 * caches/refreshes the access token, then aggregates live data from all
 * inverters on the account and serves a dashboard frontend.
 *
 * Nothing here is sent anywhere except to api.sunsynk.net. Your credentials
 * stay on your machine (in the .env file).
 */

require('dotenv').config();
const path = require('path');
const crypto = require('crypto');
const zlib = require('zlib');
const express = require('express');
const db = require('./db');

const app = express();
const PORT = process.env.PORT || 3000;

// SunSynk Connect region host. Default works for most accounts.
// Some regions use a different host; you can override with API_BASE in .env.
const API_BASE = process.env.API_BASE || 'https://api.sunsynk.net';

// Fixed "source" the SunSynk Connect web app sends; used in the login signatures.
const SOURCE = 'sunsynk';

const USERNAME = process.env.SUNSYNK_USERNAME;
const PASSWORD = process.env.SUNSYNK_PASSWORD;

// --- Battery sign convention -------------------------------------------------
// SunSynk firmware varies on whether positive battery power means charging or
// discharging. If your dashboard shows the opposite of the SunSynk app, flip
// this value between 'charging' and 'discharging'.
// Applied in exactly ONE place — extractReading() — which normalizes to
// "+ = charging" for everything downstream. The only other convention left is
// the chart's legacy "− = charging", flipped at the getHistory emit boundary.
const BATTERY_POSITIVE_MEANS = process.env.BATTERY_POSITIVE_MEANS || 'discharging';

// Panel geometry + calibration for the clear-sky "potential solar" line on the day
// chart (re-added 2026-06; the wasted-solar feature that also used these stays gone).
const LAT = Number(process.env.LAT) || -26.2041;               // latitude for sun geometry (Johannesburg default)
const SYSTEM_KWP = Number(process.env.SYSTEM_KWP) || 12.6;     // nameplate kWp (calibration ceiling)
const PANEL_TILT = Number(process.env.PANEL_TILT) || 25;       // degrees from horizontal
const PANEL_AZIMUTH = Number(process.env.PANEL_AZIMUTH) || 0;  // compass deg from North (0 = due north, SH optimal)
const SOLAR_CAL_PCT = Number(process.env.SOLAR_CAL_PERCENTILE) || 0.95;   // calibration percentile
const SOLAR_CAL_CAP_MULT = Number(process.env.SOLAR_CAL_CAP_MULT) || 1.5; // ceiling × nameplate kWp
const SOLAR_DNI_BASE = Number(process.env.SOLAR_DNI_BASE) || 0.82;        // clear-sky beam attenuation base
if (!USERNAME || !PASSWORD) {
  console.error('\n  Missing credentials. Copy .env.example to .env and fill in');
  console.error('  SUNSYNK_USERNAME and SUNSYNK_PASSWORD before starting.\n');
  process.exit(1);
}

// --- Token management --------------------------------------------------------
let tokenCache = { accessToken: null, refreshToken: null, expiresAt: 0 };

// SunSynk Connect no longer accepts a plaintext password at /oauth/token.
// Current flow (matches the web app): fetch an RSA public key, encrypt the
// password with it (PKCS#1 v1.5), sign the request with a nonce, then POST to
// /oauth/token/new.
const md5Hex = (value) => crypto.createHash('md5').update(value, 'utf8').digest('hex');
const makeNonce = () => Date.now();

function rsaEncryptPkcs1(rawKey, plaintext) {
  // rawKey is base64-encoded DER (SPKI); wrap it as PEM before loading.
  const wrapped = rawKey.replace(/(.{64})/g, '$1\n');
  const pem = `-----BEGIN PUBLIC KEY-----\n${wrapped}\n-----END PUBLIC KEY-----`;
  const ciphertext = crypto.publicEncrypt(
    { key: pem, padding: crypto.constants.RSA_PKCS1_PADDING },
    Buffer.from(plaintext, 'utf8')
  );
  return ciphertext.toString('base64');
}

async function fetchPublicKey() {
  const nonce = makeNonce();
  const sign = md5Hex(`nonce=${nonce}&source=${SOURCE}POWER_VIEW`);
  const res = await fetch(
    `${API_BASE}/anonymous/publicKey?nonce=${nonce}&source=${SOURCE}&sign=${sign}`,
    { headers: { 'Content-Type': 'application/json', Accept: 'application/json' } }
  );
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.success || !body.data) {
    throw new Error(`Could not fetch login key: ${(body && body.msg) || `HTTP ${res.status}`}`);
  }
  return body.data;
}

async function login() {
  const rawKey = await fetchPublicKey();
  const encryptedPassword = rsaEncryptPkcs1(rawKey, PASSWORD);

  const nonce = makeNonce();
  const sign = md5Hex(`nonce=${nonce}&source=${SOURCE}${rawKey.slice(0, 10)}`);

  const res = await fetch(`${API_BASE}/oauth/token/new`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({
      username: USERNAME,
      password: encryptedPassword,
      grant_type: 'password',
      client_id: 'csp-web',
      source: SOURCE,
      nonce,
      sign,
    }),
  });
  const body = await res.json().catch(() => ({}));
  const data = body && body.data;
  if (!res.ok || !body.success || !data || !data.access_token) {
    const msg = (body && body.msg) || `HTTP ${res.status}`;
    throw new Error(`Login failed: ${msg}`);
  }
  tokenCache = {
    accessToken: data.access_token,
    refreshToken: data.refresh_token,
    // refresh a minute early to be safe
    expiresAt: Date.now() + (Number(data.expires_in || 3600) - 60) * 1000,
  };
  return tokenCache.accessToken;
}

async function getToken() {
  if (tokenCache.accessToken && Date.now() < tokenCache.expiresAt) {
    return tokenCache.accessToken;
  }
  return login();
}

// --- Rate-limit backoff ------------------------------------------------------
// The Connect API publishes no rate-limit headers. If it ever answers 429 (or a
// 403 that smells like throttling), stop hammering it: cool down before the next
// call. Honors Retry-After when present, otherwise backs off exponentially up to
// a cap. Any healthy response clears the strike counter.
let cooldownUntil = 0;
let rateLimitStrikes = 0;
const BACKOFF_BASE_MS = 60 * 1000; // first cooldown ~1 min
const BACKOFF_MAX_MS = 15 * 60 * 1000; // capped at 15 min

function tripCooldown(res) {
  rateLimitStrikes += 1;
  const retryAfter = Number(res.headers.get('retry-after'));
  const wait =
    Number.isFinite(retryAfter) && retryAfter > 0
      ? retryAfter * 1000
      : Math.min(BACKOFF_MAX_MS, BACKOFF_BASE_MS * 2 ** (rateLimitStrikes - 1));
  cooldownUntil = Date.now() + wait;
  return wait;
}

async function apiGet(pathname) {
  if (Date.now() < cooldownUntil) {
    const secs = Math.ceil((cooldownUntil - Date.now()) / 1000);
    throw new Error(`Backing off SunSynk API (rate-limited) - ${secs}s remaining`);
  }

  let token = await getToken();
  const doFetch = (t) =>
    fetch(`${API_BASE}${pathname}`, {
      headers: { Authorization: `Bearer ${t}`, Accept: 'application/json' },
    });

  let res = await doFetch(token);
  if (res.status === 401) {
    // token rejected - force a fresh login once and retry
    tokenCache.expiresAt = 0;
    token = await getToken();
    res = await doFetch(token);
  }

  // No rate-limit headers exist, so treat 429 (and a throttling-style 403) as a
  // signal to back off rather than keep retrying and risk a longer block.
  if (res.status === 429 || res.status === 403) {
    const wait = tripCooldown(res);
    throw new Error(
      `API ${pathname} -> HTTP ${res.status} (rate-limited; backing off ${Math.ceil(wait / 1000)}s)`
    );
  }

  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`API ${pathname} -> HTTP ${res.status} ${(body && body.msg) || ''}`);
  }
  rateLimitStrikes = 0; // healthy response - reset the backoff escalation
  return body && body.data;
}

// --- Helpers -----------------------------------------------------------------
const num = (v) => (v === null || v === undefined || v === '' ? 0 : Number(v) || 0);

// first defined/non-null value among keys
function pick(obj, ...keys) {
  if (!obj) return undefined;
  for (const k of keys) {
    if (obj[k] !== undefined && obj[k] !== null) return obj[k];
  }
  return undefined;
}

// sum the .power field across a vip[] (per-phase) array
function sumVip(data) {
  const vip = data && (data.vip || data.pvIV);
  if (!Array.isArray(vip)) return 0;
  return vip.reduce((acc, p) => acc + num(pick(p, 'power', 'ppv', 'pac')), 0);
}

// Power (W) from the primary field(s), falling back to summing the per-phase
// vip[] ONLY when the field is absent. A legitimate 0 W must stay 0 — a falsy
// `||` fallback would silently substitute sumVip for it.
function powerField(obj, ...keys) {
  const v = pick(obj, ...keys);
  return v == null || v === '' ? sumVip(obj) : num(v);
}

// --- Data fetching -----------------------------------------------------------
async function getInverters() {
  // returns all inverters on the account
  const data = await apiGet('/api/v1/inverters?page=1&limit=20&total=0&status=-1&type=-2');
  const list = (data && (data.infos || data.records)) || [];
  return list.map((i) => ({
    sn: i.sn,
    alias: i.alias || i.sn,
    plantId: i.plant && (i.plant.id || i.plantId),
    plantName: i.plant && i.plant.name,
    model: i.model || i.equipMode || i.equipModel,
    status: i.status,
    gsn: i.gsn, // data-logger serial
    soft: (i.version && i.version.softVer) || i.softVer, // inverter firmware
    hmi: i.version && i.version.hmiVer, // HMI/display firmware
    commType: i.commTypeName,
  }));
}

// The 5 realtime endpoints every acquisition path reads (per inverter SN).
const realtimePaths = (sn) => ({
  grid: `/api/v1/inverter/grid/${sn}/realtime?sn=${sn}`,
  battery: `/api/v1/inverter/battery/${sn}/realtime?sn=${sn}&lan=en`,
  input: `/api/v1/inverter/${sn}/realtime/input`,
  load: `/api/v1/inverter/load/${sn}/realtime?sn=${sn}`,
  output: `/api/v1/inverter/${sn}/realtime/output`,
});

// Fetch all 5 raw payloads for one inverter. Both the live Overview and the
// 1/min logger consume THIS plus extractReading() — one fetch path, one field
// mapping, so the two can't drift apart. Failed endpoints come back null.
async function fetchInverterRaw(sn) {
  const paths = realtimePaths(sn);
  const keys = Object.keys(paths);
  const settled = await Promise.allSettled(keys.map((k) => apiGet(paths[k])));
  const raw = {};
  keys.forEach((k, i) => { raw[k] = settled[i].status === 'fulfilled' ? settled[i].value : null; });
  return raw;
}

async function getInverterSnapshot(inv) {
  const raw = await fetchInverterRaw(inv.sn);
  const r = extractReading(inv, raw); // the SAME field mapping the logger stores
  const b = raw.battery;

  // r.batt_w is the normalized battery sign (+ = charging) — the one convention
  // every internal consumer uses (see extractReading).
  const batStatus = r.batt_w > 5 ? 'charging' : r.batt_w < -5 ? 'discharging' : 'idle';

  return {
    sn: inv.sn,
    alias: inv.alias,
    model: inv.model,
    status: inv.status,
    gsn: inv.gsn,
    soft: inv.soft,
    hmi: inv.hmi,
    commType: inv.commType,
    pv: {
      power: Math.round(r.pv_w),
      today: r.pv_today_kwh,
      total: r.pv_total_kwh,
      strings: Array.isArray(raw.input && raw.input.pvIV)
        ? raw.input.pvIV.map((s) => ({
            id: s.id,
            no: num(pick(s, 'pvNo')),
            power: num(pick(s, 'ppv', 'power')),
            voltage: num(pick(s, 'vpv', 'volt')),
            current: num(pick(s, 'ipv', 'current')),
            today: num(pick(s, 'todayPv')),
          }))
        : [],
    },
    battery: {
      power: Math.round(Math.abs(r.batt_w)),
      signedPower: Math.round(r.batt_w), // normalized: + = charging (NOT raw firmware sign)
      status: batStatus,
      soc: r.batt_soc,
      voltage: r.batt_voltage_v,
      current: r.batt_current_a,
      temperature: r.batt_temp_c,
      capacity: num(pick(b, 'capacity', 'correctCap')), // Ah (installer setting, not pack size)
      numberOfBatteries: pick(b, 'numberOfBatteries'),
      todayCharged: r.batt_chg_today_kwh,
      todayDischarged: r.batt_dischg_today_kwh,
      totalCharged: r.batt_chg_total_kwh,
      totalDischarged: r.batt_dischg_total_kwh,
    },
    grid: {
      power: Math.round(r.grid_w),
      direction: r.grid_w >= 0 ? 'importing' : 'exporting',
      todayImport: r.grid_import_today_kwh,
      todayExport: r.grid_export_today_kwh,
      totalImport: r.grid_import_total_kwh,
      totalExport: r.grid_export_total_kwh,
      frequency: r.grid_freq_hz,
      powerFactor: r.grid_pf,
    },
    load: {
      power: Math.round(r.load_w),
      today: r.load_today_kwh,
      total: r.load_total_kwh,
      frequency: r.load_freq_hz,
    },
    output: {
      power: Math.round(r.output_w),
      voltage: r.output_volt_v,
      frequency: r.output_freq_hz,
    },
  };
}

// Today's grid import/export (kWh) integrated from our summed logger, so the
// Overview tile counts BOTH inverters (the slave's metered counter reads 0).
function gridTodayFromLog() {
  const rows = db.dayAgg(localDate());
  let imp = 0, exp = 0;
  for (const r of rows) {
    const w = r.grid_w || 0, dt = 5 / 60; // 5-min buckets → hours
    if (w > 0) imp += w * dt / 1000; else exp += -w * dt / 1000;
  }
  return { import: imp, export: exp, n: rows.length };
}

async function getOverview() {
  const inverters = await getInverters();
  const snapshots = await Promise.all(inverters.map((inv) => getInverterSnapshot(inv)));
  const plantInv = inverters.find((i) => i.plantId) || inverters[0] || {};

  const totals = snapshots.reduce(
    (acc, s) => {
      acc.pv += s.pv.power;
      acc.load += s.load.power;
      acc.grid += s.grid.power;
      acc.batteryPower += s.battery.signedPower;
      // average SOC over inverters with a VALID reading only — a dropped BMS link
      // (e.g. master after a power outage) reports 0, which would otherwise halve the
      // displayed SOC. 0 = no/invalid reading, not a real 0%.
      if (s.battery.soc > 0) { acc.socSum += s.battery.soc; acc.socCount += 1; }
      acc.todayPv += s.pv.today;
      acc.todayLoad += s.load.power ? s.load.today : 0;
      acc.todayGridImport += s.grid.todayImport;
      acc.todayGridExport += s.grid.todayExport;
      return acc;
    },
    {
      pv: 0, load: 0, grid: 0, batteryPower: 0, socSum: 0, socCount: 0,
      todayPv: 0, todayLoad: 0, todayGridImport: 0, todayGridExport: 0,
    }
  );

  const count = snapshots.length || 1;
  // Grid import/export today from our OWN logger. The per-inverter etodayFrom
  // counter only populates on the master (the slave inverter has no grid CT, so
  // its todayImport reads 0), so summing the snapshots under-counts by ~half.
  // Integrate today's logged grid_w instead — same source the day chart uses.
  const gridToday = gridTodayFromLog();
  return {
    generatedAt: new Date().toISOString(),
    plant: { id: plantInv.plantId, name: plantInv.plantName || 'Home · SunSynk' },
    totals: {
      pv: totals.pv,
      load: totals.load,
      grid: totals.grid,
      gridDirection: totals.grid >= 0 ? 'importing' : 'exporting',
      batteryPower: Math.abs(totals.batteryPower),
      // signedPower is normalized at ingestion (+ = charging), so direction is just the sign
      batteryDirection:
        Math.abs(totals.batteryPower) <= 5 ? 'idle' : totals.batteryPower > 0 ? 'charging' : 'discharging',
      soc: totals.socCount ? Math.round(totals.socSum / totals.socCount) : null,
      todayPv: Number(totals.todayPv.toFixed(2)),
      todayGridImport: Number((gridToday.n > 5 ? gridToday.import : totals.todayGridImport).toFixed(2)),
      todayGridExport: Number((gridToday.n > 5 ? gridToday.export : totals.todayGridExport).toFixed(2)),
    },
    inverters: snapshots,
  };
}

// Current date in the SERVER's local timezone as YYYY-MM-DD. SunSynk reports in
// the plant's local time, so we must NOT use UTC (toISOString) here — otherwise
// for the first hours of each local day we'd ask for yesterday's data.
function localDate(d = new Date()) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

// Map a SunSynk plant-feed series label to our key.
function plantSeriesKey(label) {
  const s = String(label || '').toLowerCase();
  if (s.includes('pv') || s.includes('solar')) return 'pv';
  if (s.includes('batt')) return 'batt';
  if (s.includes('soc') || s.includes('charge')) return 'soc';
  if (s.includes('load')) return 'load';
  if (s.includes('grid')) return 'grid';
  return null;
}

// SunSynk's plant /day feed mapped onto the 288 5-min buckets of a day, RAW
// (unscaled — see feed scaling below). Used to DOT-FILL logger-offline windows
// in the chart: the inverters keep reporting to the cloud while our logger is
// asleep, so for recent days the cloud HAS the missing minutes. Display-only:
// never written to the DB, and the frontend excludes these points from every
// total. The feed's Battery sign is already chart-convention (− = charging).
const plantFeedCache = new Map(); // day -> { at, byBucket }
async function plantFeedForDay(day) {
  const hit = plantFeedCache.get(day);
  if (hit && Date.now() - hit.at < 10 * 60 * 1000) return hit.byBucket;

  const inverters = await getInverters();
  const plantId = inverters.find((i) => i.plantId)?.plantId;
  let byBucket = null;
  if (plantId) {
    const data = await apiGet(`/api/v1/plant/energy/${plantId}/day?lan=en&date=${day}&id=${plantId}`);
    byBucket = new Array(288).fill(null);
    for (const info of (data && data.infos) || []) {
      const k = plantSeriesKey(info.label);
      if (!k) continue;
      for (const r of info.records || []) {
        const [h, mn] = String(r.time || '').split(':').map(Number);
        if (!Number.isFinite(h)) continue;
        const bkt = h * 12 + Math.floor((mn || 0) / 5);
        if (bkt < 0 || bkt > 287 || r.value == null) continue;
        (byBucket[bkt] = byBucket[bkt] || {})[k] = num(r.value);
      }
    }
    if (!byBucket.some(Boolean)) byBucket = null; // feed no longer has this day
  }

  plantFeedCache.set(day, { at: Date.now(), byBucket });
  if (plantFeedCache.size > 30) {
    const oldest = [...plantFeedCache.entries()].sort((a, b) => a[1].at - b[1].at)[0][0];
    plantFeedCache.delete(oldest);
  }
  return byBucket;
}

// --- Plant-feed scale calibration ---------------------------------------------
// SunSynk has served the plant feed BOTH ways on this parallel system: battery &
// grid as a single inverter (~half) during the original audit (§3.2/§7), and as
// the full plant sum as of 2026-06-10 (verified against logged data on multiple
// days). Don't hardcode either: derive per-series multipliers as the MEDIAN of
// real/feed over buckets where our logger and the feed overlap. ~1 = feed is
// full-sum; ~2 = feed halved. Grid borrows battery's scale when it has too few
// active buckets to calibrate (they've always moved together).
const chartValOfAgg = {
  pv: (r) => r.pv_w || 0,
  batt: (r) => -(r.batt_w || 0), // chart convention, matching the feed
  grid: (r) => r.grid_w || 0,
  load: (r) => r.load_w || 0,
};
const clampScale = (v) => Math.min(2.5, Math.max(0.4, v));
function calibrateFeedScale(feed, realByBucket) {
  const scale = {};
  const all = [];
  for (const k of Object.keys(chartValOfAgg)) {
    const ratios = [];
    for (let b = 0; b < 288; b++) {
      const r = realByBucket[b], e = feed && feed[b];
      if (!r || !e || e[k] == null) continue;
      const rv = chartValOfAgg[k](r), fv = e[k];
      if (Math.abs(rv) < 300 || Math.abs(fv) < 150) continue; // skip noise-level buckets
      if ((rv > 0) !== (fv > 0)) continue;                    // sign mismatch = transient, not scale
      ratios.push(rv / fv);
    }
    if (ratios.length >= 3) {
      ratios.sort((a, b) => a - b);
      scale[k] = clampScale(ratios[ratios.length >> 1]);
      all.push(...ratios);
    }
  }
  all.sort((a, b) => a - b);
  const overall = all.length >= 3 ? clampScale(all[all.length >> 1]) : 1;
  if (scale.grid == null) scale.grid = scale.batt != null ? scale.batt : overall;
  for (const k of Object.keys(chartValOfAgg)) if (scale[k] == null) scale[k] = overall;
  return scale;
}

// Build the 288-bucket array from db.dayAgg rows (bucket = 5-min slot of day).
function bucketizeAgg(aggRows) {
  const byBucket = new Array(288).fill(null);
  for (const r of aggRows) {
    const [h, mn] = r.hm.split(':').map(Number);
    byBucket[h * 12 + Math.floor(mn / 5)] = r;
  }
  return byBucket;
}

// Current feed scale for days we have NO local data for (the pre-logging
// fallback): calibrate against the latest logged day instead. Cached 6 h.
let feedScaleCache = { at: 0, scale: null };
async function currentFeedScale() {
  if (feedScaleCache.scale && Date.now() - feedScaleCache.at < 6 * 3600 * 1000) return feedScaleCache.scale;
  let scale = { pv: 1, batt: 1, grid: 1, load: 1 }; // feed is full-sum as of 2026-06-10
  try {
    const agg = db.dayAgg(localDate());
    if (agg.length > 5) {
      const feed = await plantFeedForDay(localDate());
      if (feed) scale = calibrateFeedScale(feed, bucketizeAgg(agg));
    }
  } catch (_) { /* keep default */ }
  feedScaleCache = { at: Date.now(), scale };
  return scale;
}

// --- Cloud gap recovery --------------------------------------------------------
// The inverters report to SunSynk's cloud independently of this machine, so the
// minutes our logger sleeps through still exist there (until the cloud drops the
// day, ~1–2 weeks). Bank them into agg_minute tagged source='plantfeed':
//   • calibrated per-day against this day's own poller overlap (§3.2 — the feed's
//     scale is unstable, never hardcode it); thin days borrow today's calibration
//   • INSERT OR IGNORE — can only fill holes, never overwrite a measurement
//   • the live edge (last 10 min) is left to the poller
//   • fully reversible: DELETE FROM agg_minute WHERE source='plantfeed'
async function recoverDay(day) {
  const missing = db.missingMinutes(day);
  if (!missing.length) return 0;
  const feed = await plantFeedForDay(day);
  if (!feed) return 0; // the cloud no longer has this day

  const pollerAgg = db.dayAgg(day, 'poller');
  const scale = pollerAgg.length >= 36 // ≥3 h of own data to calibrate against
    ? calibrateFeedScale(feed, bucketizeAgg(pollerAgg))
    : await currentFeedScale();

  const [y, mo, d] = day.split('-').map(Number);
  const dayStart = new Date(y, mo - 1, d).getTime() / 1000;
  const rows = [];
  for (const ts of missing) {
    const bkt = Math.floor((ts - dayStart) / 300);
    const e = bkt >= 0 && bkt < 288 ? feed[bkt] : null;
    if (!e) continue;
    rows.push({
      ts,
      pv_w: e.pv == null ? null : Math.round(e.pv * scale.pv),
      load_w: e.load == null ? null : Math.round(e.load * scale.load),
      batt_w: e.batt == null ? null : Math.round(-e.batt * scale.batt), // feed: − = charging → stored: + = charging
      grid_w: e.grid == null ? null : Math.round(e.grid * scale.grid),
      soc: e.soc == null ? null : Math.round(e.soc),
    });
  }
  if (!rows.length) return 0;
  const n = db.insertRecovered(rows);
  if (n) console.log(`  gap recovery: ${day} +${n} min from SunSynk cloud (scale pv ${scale.pv.toFixed(2)} batt ${scale.batt.toFixed(2)} grid ${scale.grid.toFixed(2)} load ${scale.load.toFixed(2)})`);
  return n;
}

// Sweep every logged day (the missing-minute check is local and free; the feed
// is only fetched for days that actually have holes). Runs on boot and every
// 6 h so gaps are banked well before the cloud drops them.
async function recoverAllGaps() {
  const first = db.getStats().first;
  if (!first) return;
  let total = 0;
  for (let day = localDate(new Date(first)); day <= localDate(); ) {
    try { total += await recoverDay(day); } catch (e) { console.warn(`  gap recovery failed for ${day}:`, e.message); }
    const [y, mo, d] = day.split('-').map(Number);
    day = localDate(new Date(y, mo - 1, d + 1));
  }
  if (total) console.log(`  gap recovery: banked ${total} minute(s) total`);
}

function startRecoveryWatch() {
  setTimeout(() => recoverAllGaps().catch(() => {}), 2 * 60 * 1000);
  setInterval(() => recoverAllGaps().catch(() => {}), 6 * 3600 * 1000);
}

async function getHistory(date) {
  const day = date || localDate();

  // Prefer our OWN logger. SunSynk's plant/energy feed reports Battery & Grid as
  // a SINGLE inverter (~half) on this master/slave parallel system, while Load &
  // PV are the full sum — so its series don't balance (e.g. 8 kW geyser load next
  // to a 4 kW battery). Our agg_minute sums both inverters every minute and
  // balances. Chart sign convention is SunSynk's (negative battery = charging),
  // and our logger stores positive = charging, so flip the battery sign.
  let agg = db.dayAgg(day);
  if (agg.length > 5) {
    // Opportunistic recovery: if this day still has holes and the cloud has the
    // data, bank it now (cheap when there's nothing to do; feed fetch is cached).
    if (db.dayGapMinutes(day) > 0) {
      try { if (await recoverDay(day)) agg = db.dayAgg(day); } catch (_) { /* keep what we have */ }
    }

    // Re-grid onto the full 5-min day so MISSING minutes (logger offline) become
    // explicit null points. The chart breaks/shades them instead of silently
    // compressing the time axis and drawing lines across the gap.
    const byBucket = bucketizeAgg(agg);
    let lastBucket = 287; // past days span midnight-to-midnight; today ends at the latest logged bucket
    if (day === localDate()) {
      lastBucket = 0;
      for (let i = 0; i < 288; i++) if (byBucket[i]) lastBucket = i;
    }

    const hm = (bkt) => `${String(Math.floor(bkt / 12)).padStart(2, '0')}:${String((bkt % 12) * 5).padStart(2, '0')}`;
    const mk = (label, unit, val) => ({
      label, unit,
      points: Array.from({ length: lastBucket + 1 }, (_, bkt) => {
        const r = byBucket[bkt];
        if (!r) return { time: hm(bkt), value: null }; // no data anywhere (yet) — chart shades it
        const p = { time: hm(bkt), value: val(r) };
        // buckets built purely from cloud-recovered rows are flagged est
        // (dotted in the chart) — provenance survives recovery
        if (r.feed_n > 0 && r.feed_n >= r.row_n) p.est = true;
        return p;
      }),
    });
    return {
      date: day,
      gapMinutes: db.dayGapMinutes(day),
      recoveredMinutes: db.recoveredMinutes(day),
      series: [
        mk('PV', 'W', (r) => r.pv_w || 0),
        mk('Battery', 'W', (r) => -(r.batt_w || 0)), // legacy chart convention (− = charging) — the ONLY sign flip
        mk('Grid', 'W', (r) => r.grid_w || 0),
        mk('Load', 'W', (r) => r.load_w || 0),
        mk('SOC', '%', (r) => r.soc),
      ],
    };
  }

  // Fallback for days before we started logging: SunSynk's feed, scaled by the
  // calibrated feed multipliers (approximate — the only days we can't rebuild
  // from raw per-inverter data).
  const inverters = await getInverters();
  const plantId = inverters.find((i) => i.plantId)?.plantId;
  if (!plantId) return { date: day, series: [] };
  const data = await apiGet(
    `/api/v1/plant/energy/${plantId}/day?lan=en&date=${day}&id=${plantId}`
  );
  const infos = (data && data.infos) || [];
  const scale = await currentFeedScale();
  const series = infos.map((s) => {
    const k = plantSeriesKey(s.label);
    const mul = k && k !== 'soc' ? scale[k] : 1;
    return {
      label: s.label,
      unit: s.unit,
      points: (s.records || []).map((r) => ({ time: r.time, value: r.value == null ? null : Math.round(num(r.value) * mul) })),
    };
  });
  return { date: day, series, approx: true };
}

// Earliest date this account actually has data for — roughly the plant's
// commission date. SunSynk doesn't expose it, so we derive it: walk the yearly
// energy endpoint backward to the oldest year with production, then the monthly
// endpoint to find the first day with a non-zero reading. Cached for the process
// lifetime: it only ever moves forward (and only by a day), so being stale by a
// day is harmless and beats re-walking the API on every page load.
let earliestCache; // undefined = not computed, null = no data found, string = YYYY-MM-DD
async function getEarliestDate() {
  if (earliestCache !== undefined) return earliestCache;
  const inverters = await getInverters();
  const plantId = inverters.find((i) => i.plantId)?.plantId;
  if (!plantId) return (earliestCache = null);

  // Oldest year+month with any production. Stop once an older year comes back
  // empty (data is contiguous from commissioning, so the first gap is the floor).
  const thisYear = new Date().getFullYear();
  let year = null;
  let month = null;
  for (let y = thisYear; y >= thisYear - 10; y--) {
    const data = await apiGet(`/api/v1/plant/energy/${plantId}/year?lan=en&date=${y}&id=${plantId}`);
    let minMonth = null;
    for (const info of (data && data.infos) || []) {
      for (const r of info.records || []) {
        const mm = Number(r.time);
        if (num(r.value) > 0 && Number.isFinite(mm) && (minMonth === null || mm < minMonth)) minMonth = mm;
      }
    }
    if (minMonth !== null) {
      year = y;
      month = minMonth;
    } else if (year !== null) {
      break; // already found data in a newer year; this older one is empty
    }
  }
  if (year === null) return (earliestCache = null);

  // First day with data in that month. Month-endpoint record times are YYYY-MM-DD.
  const ym = `${year}-${String(month).padStart(2, '0')}`;
  const md = await apiGet(`/api/v1/plant/energy/${plantId}/month?lan=en&date=${ym}&id=${plantId}`);
  let minDay = null;
  for (const info of (md && md.infos) || []) {
    for (const r of info.records || []) {
      if (num(r.value) > 0 && (minDay === null || r.time < minDay)) minDay = r.time;
    }
  }
  return (earliestCache = minDay || `${ym}-01`);
}

// --- Energy aggregates (week / month / year) ---------------------------------
// SunSynk's plant energy endpoints return daily kWh for a month and monthly kWh
// for a year. We normalise the labels into canonical keys and build rows the
// dashboard's period views can sum.
function energyKey(label) {
  const s = String(label || '').toLowerCase();
  if (s.includes('pv') || s.includes('generation')) return 'pv';
  if (s.includes('load') || s.includes('consumption')) return 'load';
  if (s.includes('purchas')) return 'imp';
  if (s.includes('sold') || s.includes('sell')) return 'exp';
  if (s.includes('discharge')) return 'dischg'; // must come before 'charge'
  if (s.includes('charge')) return 'chg';
  return null;
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

// Cached grid-feed multiplier (inverters ÷ CT-bearing inverters) — scales SunSynk's
// master-only grid import/export up to the full plant. Cached 6 h.
let gridMulCache = { at: 0, mul: 1 };
function gridFeedMul() {
  if (gridMulCache.at && Date.now() - gridMulCache.at < 6 * 3600 * 1000) return gridMulCache.mul;
  let mul = 1;
  try { mul = db.gridFeedScale(); } catch (_) { /* keep 1 */ }
  gridMulCache = { at: Date.now(), mul };
  return mul;
}

function rowsFromEnergy(infos, granularity) {
  const byKey = {};
  let times = [];
  for (const info of infos || []) {
    const key = energyKey(info.label);
    if (!key) continue;
    byKey[key] = {};
    for (const r of info.records || []) byKey[key][r.time] = num(r.value);
    if ((info.records || []).length > times.length) times = (info.records || []).map((r) => r.time);
  }
  // SunSynk's grid import/export is master-only (the slave has no CT), so scale it up
  // to the full plant — PV & load are already full-sum, only grid needs it. This keeps
  // these daily/monthly rows on the SAME (full) convention as the live grid-today tile,
  // so the Overview trend arrows compare like-for-like instead of full-vs-half.
  const gmul = gridFeedMul();
  return times.map((t) => {
    const pv = (byKey.pv || {})[t] || 0;
    const load = (byKey.load || {})[t] || 0;
    const imp = ((byKey.imp || {})[t] || 0) * gmul;
    const row = {
      time: t,
      pv: round1(pv),
      load: round1(load),
      imp: round1(imp),
      exp: round1(((byKey.exp || {})[t] || 0) * gmul),
      chg: round1((byKey.chg || {})[t] || 0),
      dischg: round1((byKey.dischg || {})[t] || 0),
      selfSuff: load > 0 ? Math.max(0, Math.min(100, Math.round(((load - imp) / load) * 100))) : 0,
    };
    if (granularity === 'day') {
      const d = new Date(t + 'T00:00:00');
      row.date = t;
      row.day = d.getDate();
      row.dow = d.getDay();
      row.label = DOW[d.getDay()];
      row.monthLabel = MONTHS[d.getMonth()];
    } else {
      const mi = Math.max(0, Math.min(11, Number(t) - 1));
      row.date = t;
      row.day = MONTHS[mi];
      row.label = MONTHS[mi];
      row.monthLabel = MONTHS[mi];
    }
    return row;
  });
}
const round1 = (v) => Math.round((Number(v) || 0) * 10) / 10;

async function fetchMonthRows(plantId, year, month1) {
  const date = `${year}-${String(month1).padStart(2, '0')}`;
  const data = await apiGet(`/api/v1/plant/energy/${plantId}/month?lan=en&date=${date}&id=${plantId}`);
  return rowsFromEnergy(data && data.infos, 'day');
}

async function getEnergy(period) {
  const inverters = await getInverters();
  const plantId = inverters.find((i) => i.plantId)?.plantId;
  if (!plantId) return { period, rows: [] };
  const now = new Date();
  const y = now.getFullYear();
  const m = now.getMonth() + 1; // 1-based

  if (period === 'year') {
    const data = await apiGet(`/api/v1/plant/energy/${plantId}/year?lan=en&date=${y}&id=${plantId}`);
    return { period, rows: rowsFromEnergy(data && data.infos, 'month') };
  }

  // lifetime = every month across every year the plant has data (commission year
  // → now). Same aggregation source as year/month/week, so the period tiles all
  // nest consistently. For a system younger than a year this equals 'year'.
  if (period === 'lifetime') {
    const earliest = await getEarliestDate();
    const startYear = earliest ? Number(earliest.slice(0, 4)) : y;
    const rows = [];
    for (let yr = startYear; yr <= y; yr++) {
      const data = await apiGet(`/api/v1/plant/energy/${plantId}/year?lan=en&date=${yr}&id=${plantId}`);
      rows.push(...rowsFromEnergy(data && data.infos, 'month'));
    }
    return { period, rows };
  }

  // week = the current calendar week (Monday-start) through today.
  if (period === 'week') {
    const dow = now.getDay();                 // 0=Sun … 6=Sat
    const sinceMonday = dow === 0 ? 6 : dow - 1;
    const weekStart = new Date(y, now.getMonth(), now.getDate() - sinceMonday);
    const weekStartStr = localDate(weekStart);
    let rows = await fetchMonthRows(plantId, y, m);
    // if the week began in the previous month, pull those days too
    if (weekStart.getMonth() !== now.getMonth() || weekStart.getFullYear() !== y) {
      const prevRows = await fetchMonthRows(plantId, weekStart.getFullYear(), weekStart.getMonth() + 1);
      rows = prevRows.concat(rows);
    }
    return { period, rows: rows.filter((r) => r.date >= weekStartStr) };
  }

  // month = current calendar month-to-date
  return { period, rows: await fetchMonthRows(plantId, y, m) };
}

// --- Longer-horizon trends (daily / monthly) ---------------------------------
// Daily kWh rows for the last `days`, from SunSynk's own month aggregation (same
// source as the Overview, so the numbers reconcile). Spans month boundaries.
async function getTrendDaily(days) {
  const inverters = await getInverters();
  const plantId = inverters.find((i) => i.plantId)?.plantId;
  if (!plantId) return [];
  const now = new Date();
  const months = new Set();
  for (let k = 0; k < days; k++) {
    const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - k);
    months.add(`${d.getFullYear()}-${d.getMonth() + 1}`);
  }
  let rows = [];
  for (const ym of months) {
    const [yy, mm] = ym.split('-').map(Number);
    rows = rows.concat(await fetchMonthRows(plantId, yy, mm));
  }
  rows.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  return rows.slice(-days);
}

// Daily rows between two YYYY-MM-DD dates (inclusive), spanning months as needed.
async function getDaysInRange(plantId, startStr, endStr) {
  const start = new Date(startStr + 'T00:00:00');
  const end = new Date(endStr + 'T00:00:00');
  let cur = new Date(start.getFullYear(), start.getMonth(), 1);
  let rows = [];
  while (cur <= end) {
    rows = rows.concat(await fetchMonthRows(plantId, cur.getFullYear(), cur.getMonth() + 1));
    cur = new Date(cur.getFullYear(), cur.getMonth() + 1, 1);
  }
  return rows.filter((r) => r.date >= startStr && r.date <= endStr);
}

// Period-over-period comparison for the Overview trend arrows. Compares the
// current period-to-date against the SAME elapsed slice of the previous period
// (e.g. month days 1..today vs last month days 1..today), so the % is fair and
// not an apples-to-oranges partial-vs-full.
async function getCompare() {
  const inverters = await getInverters();
  const plantId = inverters.find((i) => i.plantId)?.plantId;
  if (!plantId) return {};
  const now = new Date();
  const y = now.getFullYear(), mo = now.getMonth(), d = now.getDate();
  const today = localDate(now);
  const yesterday = localDate(new Date(y, mo, d - 1));
  const dow = now.getDay(), sinceMon = dow === 0 ? 6 : dow - 1;
  const weekStart = localDate(new Date(y, mo, d - sinceMon));
  const prevWeekStart = localDate(new Date(y, mo, d - sinceMon - 7));
  const prevWeekEnd = localDate(new Date(y, mo, d - 7));
  const monthStart = localDate(new Date(y, mo, 1));
  const lastMonthStart = localDate(new Date(y, mo - 1, 1));
  const lastMonthSameDay = localDate(new Date(y, mo - 1, d)); // same elapsed days into last month

  const earliest = [yesterday, prevWeekStart, lastMonthStart].sort()[0];
  const days = await getDaysInRange(plantId, earliest, today);
  const sum = (a, b) => days.filter((r) => r.date >= a && r.date <= b)
    .reduce((o, r) => ({ pv: o.pv + r.pv, load: o.load + r.load, imp: o.imp + r.imp }), { pv: 0, load: 0, imp: 0 });

  // year: this-year-to-date vs last-year-to-same-date. This year's monthly totals
  // already include the current month as month-to-date, so summing them is YTD.
  // Last year = its full months before this month + its current month up to today's day.
  const sumYr = (rows) => rows.reduce((o, r) => ({ pv: o.pv + r.pv, load: o.load + r.load, imp: o.imp + r.imp }), { pv: 0, load: 0, imp: 0 });
  const yrRows = (data) => rowsFromEnergy(data && data.infos, 'month');
  const thisYearRows = yrRows(await apiGet(`/api/v1/plant/energy/${plantId}/year?lan=en&date=${y}&id=${plantId}`));
  const lastYearRows = yrRows(await apiGet(`/api/v1/plant/energy/${plantId}/year?lan=en&date=${y - 1}&id=${plantId}`));
  const monthNum = mo + 1;
  const lyFull = sumYr(lastYearRows.filter((r) => Number(r.date) < monthNum));
  const lyPartial = sumYr(await getDaysInRange(plantId, localDate(new Date(y - 1, mo, 1)), localDate(new Date(y - 1, mo, d))));
  const yearCur = sumYr(thisYearRows);
  const yearPrev = { pv: lyFull.pv + lyPartial.pv, load: lyFull.load + lyPartial.load, imp: lyFull.imp + lyPartial.imp };

  return {
    today: { cur: sum(today, today), prev: sum(yesterday, yesterday) },
    week: { cur: sum(weekStart, today), prev: sum(prevWeekStart, prevWeekEnd) },
    month: { cur: sum(monthStart, today), prev: sum(lastMonthStart, lastMonthSameDay) },
    year: { cur: yearCur, prev: yearPrev },
  };
}

// Monthly kWh rows across every year the plant has data (commission → now).
// Tagged with year + month so the frontend can also roll them into seasons.
async function getTrendMonthly() {
  const inverters = await getInverters();
  const plantId = inverters.find((i) => i.plantId)?.plantId;
  if (!plantId) return [];
  const earliest = await getEarliestDate();
  const startYear = earliest ? Number(earliest.slice(0, 4)) : new Date().getFullYear();
  const endYear = new Date().getFullYear();
  const out = [];
  for (let yr = startYear; yr <= endYear; yr++) {
    const data = await apiGet(`/api/v1/plant/energy/${plantId}/year?lan=en&date=${yr}&id=${plantId}`);
    for (const r of rowsFromEnergy(data && data.infos, 'month')) {
      const month = Number(r.date);
      out.push({ ym: `${yr}-${String(month).padStart(2, '0')}`, year: yr, month, label: r.label, pv: r.pv, load: r.load, imp: r.imp, exp: r.exp });
    }
  }
  return out;
}

// NOTE (2026-06): the Open-Meteo weather widget (ambient temp · condition · sunrise/
// sunset daylight track) was removed — low-use decoration. Removed: getWeather(),
// weatherDesc(), GET /api/weather, the LAT/LON env knobs, and the `weather` field on
// /api/overview. (Battery pack temperature in the balance banner is unrelated and stays.)

// --- History logger ----------------------------------------------------------
// The SunSynk cloud only keeps a few days, so we poll on a server-side timer
// (independent of whether a browser is open) and bank each reading to SQLite.
// Over time this becomes the real history the cloud won't give us.
const LOG_INTERVAL_MS = Number(process.env.LOG_INTERVAL_MS) || 60 * 1000;

// epoch seconds for the current minute (UTC) — the dedup key for a sample
const nowMinuteEpoch = () => Math.floor(Date.now() / 60000) * 60;

// Pull the typed per-inverter fields out of one inverter's 5 raw realtime payloads.
function extractReading(inv, raw) {
  const g = raw.grid, b = raw.battery, p = raw.input, l = raw.load, o = raw.output;
  const battPowerRaw = num(pick(b, 'power')); // signed per firmware (see BATTERY_POSITIVE_MEANS)
  const battSigned = BATTERY_POSITIVE_MEANS === 'charging' ? battPowerRaw : -battPowerRaw; // normalise: + = charging
  const outVip0 = (o && Array.isArray(o.vip) && o.vip[0]) || {};
  return {
    sn: inv.sn,
    status: inv.status,
    pv_w: powerField(p, 'pac', 'solarPower'),
    pv_today_kwh: num(pick(p, 'etoday')),
    pv_total_kwh: num(pick(p, 'etotal')),
    batt_power_w: battPowerRaw,
    batt_w: battSigned,
    batt_soc: num(pick(b, 'soc', 'bmsSoc')),
    batt_voltage_v: num(pick(b, 'voltage', 'bmsVolt')),
    batt_current_a: num(pick(b, 'current', 'bmsCurrent')),
    batt_temp_c: num(pick(b, 'temp', 'bmsTemp')), // raw, incl. junk like -100 (filter on read)
    batt_chg_today_kwh: num(pick(b, 'etodayChg')),
    batt_dischg_today_kwh: num(pick(b, 'etodayDischg')),
    batt_chg_total_kwh: num(pick(b, 'etotalChg')),
    batt_dischg_total_kwh: num(pick(b, 'etotalDischg')),
    grid_w: powerField(g, 'pac'), // + import / - export
    grid_import_today_kwh: num(pick(g, 'etodayFrom')),
    grid_export_today_kwh: num(pick(g, 'etodayTo')),
    grid_import_total_kwh: num(pick(g, 'etotalFrom')),
    grid_export_total_kwh: num(pick(g, 'etotalTo')),
    grid_freq_hz: num(pick(g, 'fac', 'freq')),
    grid_pf: num(pick(g, 'pf')),
    load_w: powerField(l, 'pac', 'totalPower'), // power only — 'totalUsed' is a kWh counter
    load_today_kwh: num(pick(l, 'dailyUsed')),
    load_total_kwh: num(pick(l, 'totalUsed')),
    load_freq_hz: num(pick(l, 'loadFac', 'fac')),
    output_w: powerField(o, 'pac'),
    output_volt_v: num(pick(outVip0, 'volt', 'voltage')),
    output_freq_hz: num(pick(o, 'fac', 'freq')),
  };
}

// One live poll: fetch every inverter's 5 raw endpoints, then store the rich
// per-inverter readings + per-string + metadata + the gzipped raw payload, plus
// a summed row on the aggregate spine.
async function collectAndLog() {
  const inverters = await getInverters();
  const perInv = await Promise.all(inverters.map(async (inv) => ({ inv, raw: await fetchInverterRaw(inv.sn) })));

  const ts = nowMinuteEpoch();
  const readings = perInv.map(({ inv, raw }) => extractReading(inv, raw));

  const strings = [];
  perInv.forEach(({ inv, raw }) => {
    ((raw.input && raw.input.pvIV) || []).forEach((s, k) => strings.push({
      sn: inv.sn,
      no: num(pick(s, 'pvNo')) || k + 1,
      volt: num(pick(s, 'vpv', 'volt')),
      current: num(pick(s, 'ipv', 'current')),
      power: num(pick(s, 'ppv', 'power')),
      today: num(pick(s, 'todayPv')),
    }));
  });

  const meta = perInv.map(({ inv, raw }) => ({
    sn: inv.sn, alias: inv.alias, model: inv.model, soft: inv.soft, hmi: inv.hmi,
    gsn: inv.gsn, comm: inv.commType,
    capacity_ah: num(pick(raw.battery, 'capacity', 'correctCap')),
    number_of_batteries: pick(raw.battery, 'numberOfBatteries'),
    plant_id: inv.plantId, plant_name: inv.plantName,
  }));

  // plant-aggregate spine row (summed; SOC averaged over VALID readings only)
  const sum = (f) => readings.reduce((a, r) => a + (Number(f(r)) || 0), 0);
  // a dropped BMS link reports batt_soc 0 — exclude those so one bad inverter doesn't
  // halve the logged SOC (0 = no/invalid reading, not a real 0%).
  const socV = readings.filter((r) => Number(r.batt_soc) > 0);
  const agg = {
    pv_w: sum((r) => r.pv_w), load_w: sum((r) => r.load_w),
    batt_w: sum((r) => r.batt_w), grid_w: sum((r) => r.grid_w),
    soc: socV.length ? Math.round(socV.reduce((a, r) => a + Number(r.batt_soc), 0) / socV.length) : null,
  };

  const payload = {
    generatedAt: new Date(ts * 1000).toISOString(),
    inverters: perInv.map(({ inv, raw }) => ({ sn: inv.sn, alias: inv.alias, plantId: inv.plantId, raw })),
  };
  const json = Buffer.from(JSON.stringify(payload));
  const rawGz = zlib.gzipSync(json);

  db.recordPoll({ ts, agg, readings, strings, meta, rawGz, rawBytes: json.length });
}

function startLogger() {
  const tick = () => collectAndLog().catch((e) => console.warn('  log poll failed:', e.message));
  tick(); // log one immediately on boot
  setInterval(tick, LOG_INTERVAL_MS);
}

// Nightly physics audit (DATA_PIPELINE.md §9A/§9B): every day's energy balance
// must close, and the battery sign must agree with SOC movement. Runs shortly
// after boot, then every 24 h; flagged days land in the server log. Same engine
// as /api/integrity and `npm run check`.
function startIntegrityWatch() {
  const run = () => {
    try {
      const rep = db.integrityReport(60);
      const bad = rep.days.filter((d) => d.flags.length);
      if (bad.length) {
        console.warn(`  integrity: ${bad.length} day(s) FLAGGED — ${bad.map((d) => `${d.date} [${d.flags.join(',')}]`).join('; ')}`);
      } else if (rep.days.length) {
        console.log(`  integrity: all ${rep.days.length} day(s) balance ok`);
      }
    } catch (e) {
      console.warn('  integrity check failed:', e.message);
    }
  };
  setTimeout(run, 90 * 1000); // after the first poll has landed
  setInterval(run, 24 * 3600 * 1000);
}

// --- Potential solar (calibrated clear-sky) -----------------------------------
// The dotted "what a clear day could make" line on the day chart. Shape is from sun
// geometry (peaks at solar noon for the panels' tilt/azimuth); magnitude is calibrated
// to the panels' own demonstrated un-curtailed output, capped at nameplate. NOTE: this
// is a visual reference only — the wasted-solar feature that once derived numbers from
// it is gone (curtailed solar is unmeasurable), so don't read kWh off this.
const RAD = Math.PI / 180;
function dayOfYear(d) { const s = new Date(d.getFullYear(), 0, 0); return Math.floor((d - s) / 86400000); }
function clearSkyShape(d) { // relative plane-of-array clear-sky output 0..1
  const N = dayOfYear(d);
  const decl = RAD * 23.45 * Math.sin(RAD * 360 * (284 + N) / 365);
  const w = RAD * 15 * ((d.getHours() * 60 + d.getMinutes()) / 60 - 12); // hour angle
  const phi = RAD * LAT;
  const sE = -Math.cos(decl) * Math.sin(w);
  const sN = Math.cos(phi) * Math.sin(decl) - Math.sin(phi) * Math.cos(decl) * Math.cos(w);
  const sU = Math.sin(phi) * Math.sin(decl) + Math.cos(phi) * Math.cos(decl) * Math.cos(w);
  if (sU <= 0) return 0; // sun below horizon
  const b = RAD * PANEL_TILT, g = RAD * PANEL_AZIMUTH;
  const nE = Math.sin(b) * Math.sin(g), nN = Math.sin(b) * Math.cos(g), nU = Math.cos(b);
  const cosInc = Math.max(0, sE * nE + sN * nN + sU * nU);
  const dni = Math.pow(SOLAR_DNI_BASE, Math.pow(1 / Math.max(0.05, sU), 0.678)); // air-mass attenuation
  return dni * cosInc;
}
// Scale (W) = demonstrated clear-sky output, a high percentile of actual÷clear-sky over
// un-curtailed daytime samples; capped at nameplate × cap-mult. Cached 6 h.
let solarCal = { at: 0, scaleW: 0 };
function solarScaleW() {
  if (solarCal.scaleW && Date.now() - solarCal.at < 6 * 3600 * 1000) return solarCal.scaleW;
  let scaleW = SYSTEM_KWP * 1000 * 0.82; // fallback until there's enough data
  try {
    const ratios = [];
    for (const r of db.calSamples()) {
      const shape = clearSkyShape(new Date(r.ts * 1000));
      if (shape > 0.25) ratios.push(r.pv_w / shape);
    }
    if (ratios.length >= 20) { ratios.sort((a, b) => a - b); scaleW = ratios[Math.floor(ratios.length * SOLAR_CAL_PCT)]; }
  } catch (_) { /* keep fallback */ }
  solarCal = { at: Date.now(), scaleW: Math.round(Math.min(scaleW, SYSTEM_KWP * 1000 * SOLAR_CAL_CAP_MULT)) };
  return solarCal.scaleW;
}
function potentialProfile(dateStr) { // per-5-min potential (W) for a YYYY-MM-DD
  const [y, mo, da] = dateStr.split('-').map(Number);
  const scaleW = solarScaleW();
  const points = [];
  for (let t = 0; t < 1440; t += 5) {
    const d = new Date(y, mo - 1, da, Math.floor(t / 60), t % 60);
    points.push({ t, w: Math.round(scaleW * clearSkyShape(d)) });
  }
  return points;
}

// NOTE (2026-06): the overnight "battery at midnight" forecast card was removed.
// The per-segment usage card (segmentPower / /api/trends/segments) now covers the
// overnight breakdown, and the midnight target was obsoleted by the grid-backstop
// floor. Removed with it: overnightModel(), GET /api/overnight, db.eveningRows(),
// db.loadByDayHour(), db.samplesInHours(), and the median/mean helpers. git-revert to restore.

// NOTE (2026-06): the "wasted / surplus solar" feature was removed. Curtailed solar
// is unmeasurable — when the battery is full and there's nowhere to send power, the
// inverter throttles the panels and the un-made energy never reaches any sensor. The
// old estimate (clear-sky model − actual, deflated by a day-clearness factor) was a
// soft guess, and the battery-sizing case turned out to be reliability-driven, not
// surplus-driven. Removed: dayClearness(), getSurplusByDay(), todaySurplus(),
// GET /api/trends/surplus, db.daySamples(), db.samplesOnDate() — and (2026-06) the
// whole clear-sky model + dotted chart line too (see the note above clearSkyShape's
// former home). To restore any of it, git-revert.

// Average power used per day-segment, with the load split by source (solar/battery/
// grid). The honest, MEASURED replacement for the surplus view.
function segmentUsage(days = 7) {
  return db.segmentPower(days);
}

// --- Routes ------------------------------------------------------------------
app.get('/api/overview', async (req, res) => {
  try {
    res.json(await getOverview());
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

app.get('/api/history', async (req, res) => {
  try {
    res.json(await getHistory(req.query.date));
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

// Earliest day with data (≈ commission date) — lower bound for the day picker.
app.get('/api/history/earliest', async (req, res) => {
  try {
    res.json({ earliest: await getEarliestDate() });
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

app.get('/api/energy', async (req, res) => {
  const period = ['week', 'month', 'year', 'lifetime'].includes(req.query.period) ? req.query.period : 'week';
  try {
    res.json(await getEnergy(period));
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

// Logged-history stats (row count, day count, date range) — quick health check.
app.get('/api/db/stats', (req, res) => {
  try {
    res.json(db.getStats());
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Average power profile by hour-of-day from the local log — the basis for
// "best time to run the geyser" (compare avg PV vs load to find solar surplus).
app.get('/api/trends/by-hour', (req, res) => {
  const days = Math.max(1, Math.min(365, Number(req.query.days) || 14));
  try {
    res.json({ days, hours: db.byHour(days) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Daily kWh for the last N days (bar chart).
app.get('/api/trends/daily', async (req, res) => {
  const days = Math.max(1, Math.min(120, Number(req.query.days) || 30));
  try {
    res.json({ days, rows: await getTrendDaily(days) });
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

// Monthly kWh across all years (bar chart + seasonal rollup on the frontend).
app.get('/api/trends/monthly', async (req, res) => {
  try {
    res.json({ rows: await getTrendMonthly() });
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

// Period-over-period comparison (for the Overview trend arrows).
app.get('/api/trends/compare', async (req, res) => {
  try {
    res.json(await getCompare());
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

// Calibrated potential-solar profile for a date (the dotted clear-day line).
app.get('/api/trends/potential', (req, res) => {
  const date = /^\d{4}-\d{2}-\d{2}$/.test(req.query.date || '') ? req.query.date : localDate();
  try {
    res.json({ date, scaleW: solarScaleW(), points: potentialProfile(date) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Average power per day-segment + the load's source split (solar/battery/grid).
app.get('/api/trends/segments', (req, res) => {
  const days = Math.max(1, Math.min(120, Number(req.query.days) || 7));
  try {
    res.json({ days, segments: segmentUsage(days) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Physics integrity audit (§9A/§9B): per-day energy-balance residual, battery
// sign-vs-SOC agreement, and missing minutes. Same engine as `npm run check`.
app.get('/api/integrity', (req, res) => {
  const days = Math.max(1, Math.min(400, Number(req.query.days) || 60));
  try {
    res.json(db.integrityReport(days));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Battery balance: live SOC/voltage spread between the two inverter banks (desync
// monitor). Returns current spread, status, and the recent max so drift is visible.
app.get('/api/balance', (req, res) => {
  try {
    const rows = db.bankBalance(72);
    const banks = db.latestBanks();
    const last = rows.length ? rows[rows.length - 1] : null;
    const nowS = Date.now() / 1000;
    const maxIn = (h) => { const s = rows.filter((r) => r.ts >= nowS - h * 3600); return s.length ? Math.round(Math.max(...s.map((r) => r.socspread)) * 10) / 10 : null; };
    const socSpread = last ? Math.round(last.socspread * 10) / 10 : null;

    // SUSTAINED status: the spread must stay in an elevated band for a continuous
    // ~10 min before we flag it, so brief transients (banks spreading during a hard
    // charge, then re-converging) don't trip the banner. We require the MINIMUM
    // spread across the last 10 min to clear a band — one dip below resets it.
    const SUSTAIN_S = 10 * 60;
    const recent = rows.filter((r) => r.ts >= nowS - SUSTAIN_S);
    const haveWindow = recent.length >= 2 && (recent[recent.length - 1].ts - recent[0].ts) >= 9 * 60;
    let status;
    if (socSpread == null) status = 'unknown';
    else if (!haveWindow) status = 'balanced'; // not enough continuous history to confirm a drift yet
    else {
      const minSpread = Math.min(...recent.map((r) => r.socspread));
      status = minSpread >= 5 ? 'drifting' : minSpread >= 3 ? 'watch' : 'balanced';
    }
    // elevated right now but not yet sustained 10 min — stays calm, noted in the tooltip
    const liveBand = socSpread == null ? 'unknown' : socSpread < 3 ? 'balanced' : socSpread < 5 ? 'watch' : 'drifting';
    const pending = liveBand !== 'unknown' && liveBand !== 'balanced' && status === 'balanced';

    const health = db.batteryHealth(); // temp + time-at-full (longevity watch)
    res.json({
      banks, socSpread,
      vSpread: last ? Math.round(last.vspread * 100) / 100 : null,
      status, pending, max24h: maxIn(24), max72h: maxIn(72), samples: rows.length,
      tempC: health.tempC,
      hrsAtFullToday: health.hrsAtFullToday,
      tempHot: health.tempC != null && health.tempC > 35, // LFP ageing climbs above ~35°C
      stale: !last || (nowS - last.ts) > 600, // >10 min since last paired reading
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Raw passthrough for verifying field names / sign conventions against your kit
app.get('/api/debug/:sn', async (req, res) => {
  const paths = realtimePaths(req.params.sn);
  try {
    const keys = Object.keys(paths);
    const settled = await Promise.allSettled(keys.map((k) => apiGet(paths[k])));
    const out = {};
    keys.forEach((k, i) => { out[k] = settled[i].status === 'fulfilled' ? settled[i].value : { error: settled[i].reason.message }; });
    res.json(out);
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

app.use(express.static(path.join(__dirname, 'public')));

app.listen(PORT, () => {
  console.log(`\n  SunSynk dashboard running at  http://localhost:${PORT}`);
  db.initDb();
  console.log(`  logging history to           ${db.DB_PATH}\n`);
  startLogger();          // bank a reading every minute from here on
  startIntegrityWatch();  // nightly §9A/§9B physics audit (CLI: npm run check)
  startRecoveryWatch();   // bank logger-offline minutes from SunSynk's cloud (source='plantfeed')
  // NOTE: never seed agg_minute from SunSynk's plant/day feed — it reports
  // Battery & Grid as a SINGLE inverter (~half) with the opposite battery sign,
  // which corrupted history once before (see DATA_PIPELINE.md §7). The poller is
  // the only writer; pre-logging days render via the live "≈ estimated" fallback.
});
