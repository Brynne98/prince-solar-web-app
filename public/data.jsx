// ============================================================================
// data.jsx — LIVE data layer. Fetches the local Node server (server.js), which
// proxies SunSynk Connect, and maps the responses into the shapes the UI uses.
//   /api/overview          -> snapshot  { updated, plant, aggregate, inverters }
//   /api/history?date=     -> day series { points:[{t,pv,load,batt,grid,soc}], totals }
//   /api/energy?period=    -> days[]     [{ pv, load, imp, chg, dischg, selfSuff, ... }]
// (Field names mirror API.md; the old mock generators were removed.)
// ============================================================================

const TYPICAL_DAYS = 7; // Live "usually N%" and the Trends hourly default.
const BATT_MAX_KW = 5.0; // charge/discharge ceiling per inverter (display only)

// ---- transport -------------------------------------------------------------
// The backend is Supabase now: each old Express endpoint is a Postgres function
// returning the SAME JSON shape. Rather than touch 15 call sites, getJSON keeps its
// signature and routes the path to the matching RPC — everything below this line is
// unchanged from the Express version.
//
// The five plant-level endpoints (energy, daily, monthly, compare, earliest) read a
// Postgres cache that sync-plant-energy refreshes daily, rather than calling SunSynk
// per request. Same shapes; the browser just never touches the vendor API.
//
// Multi-plant: every RPC takes p_plant. null means "my only/first plant" server-side;
// the header's plant selector sets window.CURRENT_PLANT and everything follows.
window.CURRENT_PLANT = window.CURRENT_PLANT ?? null;
window.PLANT_CURRENCY = window.PLANT_CURRENCY || 'ZAR';
window.setCurrentPlant = (id, currency) => {
  window.CURRENT_PLANT = id == null ? null : Number(id);
  if (currency) window.PLANT_CURRENCY = currency;
};

const ROUTES = {
  '/api/overview':         () => ['api_overview', {}],
  '/api/history':          (q) => ['api_history', { p_date: q.date || null }],
  '/api/history/earliest': () => ['api_history_earliest', {}],
  '/api/energy':           (q) => ['api_energy', { p_period: q.period || 'week' }],
  '/api/db/stats':         () => ['api_db_stats', {}],
  '/api/trends/by-hour':   (q) => ['api_trends_by_hour', { p_days: Number(q.days) || 14 }],
  '/api/trends/daily':     (q) => ['api_trends_daily', { p_days: Number(q.days) || 30 }],
  '/api/trends/monthly':   () => ['api_trends_monthly', {}],
  '/api/trends/compare':   () => ['api_trends_compare', {}],
  '/api/trends/segments':  (q) => ['api_trends_segments', { p_days: Number(q.days) || 7 }],
  '/api/trends/potential': (q) => ['api_trends_potential', { p_date: q.date || null }],
  '/api/balance':          () => ['api_balance', {}],
};

async function getJSON(url) {
  const [path, qs] = String(url).split('?');
  const q = Object.fromEntries(new URLSearchParams(qs || ''));

  const route = ROUTES[path];
  if (!route) throw new Error('No RPC mapped for ' + path);

  const [fn, params] = route(q);
  const { data, error } = await window.sb.rpc(fn, { ...params, p_plant: window.CURRENT_PLANT });
  if (error) throw new Error(error.message || 'RPC ' + fn + ' failed');
  return data || {};
}

const isOnline = (s) => s === 1 || s === '1' || s === 'online' || s === true;

// ---- /api/overview -> snapshot ---------------------------------------------
function mapInverter(s) {
  const out = {
    sn: s.sn,
    alias: s.alias || s.sn,
    model: s.model || '—',
    status: isOnline(s.status) ? 'online' : 'offline',
    soft: s.soft || '—',
    hmi: s.hmi || '—',
    gsn: s.gsn || '—',
    commissioned: s.commType || '—', // no commissioning date in the API; show link type
    pvNow: s.pv.power,
    pvToday: s.pv.today,
    pvTotal: s.pv.total,
    output: s.output.power,
    battPower: s.battery.power,
    battState: s.battery.status,
    battSoc: s.battery.soc,
    battVolt: s.battery.voltage,
    battCurrent: s.battery.current,
    battTemp: s.battery.temperature,
    battCap: s.battery.capacity,
    numberOfBatteries: s.battery.numberOfBatteries ?? 1,
    secondBank: false,
    chgToday: s.battery.todayCharged,
    dischgToday: s.battery.todayDischarged,
    chgTotal: s.battery.totalCharged,
    dischgTotal: s.battery.totalDischarged,
    grid: s.grid.power, // signed: + import / − export
    gridFromToday: s.grid.todayImport,
    gridFromTotal: s.grid.totalImport,
    gridFreq: s.grid.frequency || s.output.frequency || 0,
    gridPf: s.grid.powerFactor || 0,
    load: s.load.power,
    loadToday: s.load.today,
    loadTotal: s.load.total,
    loadFreq: s.load.frequency || s.output.frequency || 0,
    strings: (s.pv.strings || []).map((st, i) => ({
      no: st.no || i + 1, v: st.voltage, i: st.current, p: st.power, today: st.today,
    })),
    phases: [{ volt: s.output.voltage, current: s.output.voltage ? s.output.power / s.output.voltage : 0, power: s.output.power }],
    ups: { l1: s.load.power, l2: 0, l3: 0 },
  };
  return out;
}

function aggregate(invs, totals) {
  const n = invs.length || 1;
  const sum = (f) => invs.reduce((a, x) => a + (Number(f(x)) || 0), 0);
  const temps = invs.map((x) => x.battTemp).filter((t) => t != null && t > -50 && t <= 120);
  const gf = invs.find((x) => x.gridFreq > 0);
  const r1 = (v) => Math.round(v * 10) / 10; // 1-decimal (kills float-sum artifacts like 18.29999)
  return {
    pvNow: totals.pv != null ? totals.pv : sum((x) => x.pvNow),
    pvToday: r1(totals.todayPv != null ? totals.todayPv : sum((x) => x.pvToday)),
    pvTotal: r1(sum((x) => x.pvTotal)),
    battSoc: totals.soc != null ? totals.soc : Math.round(sum((x) => x.battSoc) / n),
    battPower: totals.batteryPower != null ? totals.batteryPower : sum((x) => x.battPower),
    battState: totals.batteryDirection || 'idle',
    battVoltage: r1(sum((x) => x.battVolt) / n),
    battCurrent: r1(sum((x) => x.battCurrent)),
    battTemp: temps.length ? r1(temps.reduce((a, b) => a + b, 0) / temps.length) : (invs[0] ? invs[0].battTemp : 0),
    battChgToday: r1(sum((x) => x.chgToday)),
    battDischgToday: r1(sum((x) => x.dischgToday)),
    battChgTotal: r1(sum((x) => x.chgTotal)),
    battDischgTotal: r1(sum((x) => x.dischgTotal)),
    gridPower: totals.grid != null ? totals.grid : sum((x) => x.grid),
    // true = mains seen, false = supply down, null/undefined = this firmware doesn't
    // report grid voltage, so the UI says nothing rather than guessing (migration 0015)
    gridPresent: totals.gridPresent,
    gridFromToday: r1(totals.todayGridImport != null ? totals.todayGridImport : sum((x) => x.gridFromToday)),
    gridFromTotal: r1(sum((x) => x.gridFromTotal)),
    gridFreq: gf ? gf.gridFreq : (invs[0] ? invs[0].gridFreq : 0),
    gridPf: invs[0] ? invs[0].gridPf : 0,
    loadNow: totals.load != null ? totals.load : sum((x) => x.load),
    loadToday: r1(sum((x) => x.loadToday)),
    loadTotal: r1(sum((x) => x.loadTotal)),
  };
}

async function fetchSnapshot() {
  const api = await getJSON('/api/overview');
  const inverters = (api.inverters || []).map(mapInverter);
  // Battery capacity and reserve are not derived here (SunSynk under-reports Ah/V) —
  // they come from app_config via api_overview, which is also what the phone alerts
  // read. Pass them straight through; null until the first snapshot lands.
  if (api.config && api.config.currency) window.PLANT_CURRENCY = api.config.currency;
  return {
    updated: new Date(api.generatedAt || Date.now()),
    plant: api.plant || { id: null, name: 'My plant' },
    aggregate: aggregate(inverters, api.totals || {}),
    config: api.config || null,
    inverters,
  };
}

// ---- /api/history -> day power series --------------------------------------
function dayKey(label) {
  const s = String(label || '').toLowerCase();
  if (s.includes('pv') || s.includes('solar')) return 'pv';
  if (s.includes('batt')) return 'batt';
  if (s.includes('soc') || s.includes('charge')) return 'soc';
  if (s.includes('load')) return 'load';
  if (s.includes('grid')) return 'grid';
  return null;
}

async function fetchDay(date) {
  const api = await getJSON('/api/history' + (date ? '?date=' + date : ''));
  const by = {};
  (api.series || []).forEach((s) => { const k = dayKey(s.label); if (k) by[k] = s.points || []; });
  const base = by.pv || by.load || by.soc || [];
  const dt = 5 / 60; // 5-minute samples
  let chg = 0, dischg = 0, imp = 0, pvK = 0, loadK = 0;
  const points = base.map((p, i) => {
    // null = the logger was offline for this bucket — keep it null so the chart
    // can break the line / shade the gap (a 0 here would be a lie).
    // est = cloud-recovered bucket (source='plantfeed' in the DB); drawn dotted.
    // Recovered minutes are part of history, so totals include them — same as
    // every DB-side metric.
    const at = (k) => { const arr = by[k]; const v = arr && arr[i] ? arr[i].value : null; return v == null ? null : Number(v) || 0; };
    const est = !!(by.pv && by.pv[i] && by.pv[i].est);
    const tm = String(p.time || '00:00').split(':');
    const t = (Number(tm[0]) || 0) * 60 + (Number(tm[1]) || 0);
    const pv = at('pv'), load = at('load'), batt = at('batt'), grid = at('grid'), soc = at('soc');
    if (pv != null) pvK += pv * dt / 1000;
    if (load != null) loadK += load * dt / 1000;
    if (batt != null) { if (batt < 0) chg += -batt * dt / 1000; else dischg += batt * dt / 1000; } // SunSynk series: −batt = charging
    if (grid != null && grid > 0) imp += grid * dt / 1000;
    return { t, pv, load, batt, grid, soc, est };
  });
  return {
    points,
    approx: !!api.approx, // pre-logging day: the whole day is SunSynk's feed (calibrated scale)
    gapMinutes: api.gapMinutes || 0, // minutes with no data from anywhere
    recoveredMinutes: api.recoveredMinutes || 0, // minutes recovered from SunSynk's cloud
    totals: {
      pv: +pvK.toFixed(1), load: +loadK.toFixed(1),
      chg: +chg.toFixed(1), dischg: +dischg.toFixed(1), imp: +imp.toFixed(1),
    },
  };
}

// Earliest date with data (≈ commission date). Bounds the day picker; null if
// unknown (treated as "no lower limit" by the UI).
async function fetchEarliest() {
  try { const api = await getJSON('/api/history/earliest'); return api.earliest || null; }
  catch (e) { return null; }
}

// ---- /api/energy -> daily/monthly aggregate rows ---------------------------
async function fetchEnergy(period) {
  const api = await getJSON('/api/energy?period=' + period);
  return api.rows || [];
}

// ---- /api/trends -> hour-of-day profile from the local log -----------------
async function fetchHourly(days) {
  const n = days || TYPICAL_DAYS;
  const byHour = await getJSON('/api/trends/by-hour?days=' + n);
  return { days: byHour.days || n, hours: byHour.hours || [] };
}
async function fetchTrends(days) {
  const [byHour, stats] = await Promise.all([
    fetchHourly(days),
    getJSON('/api/db/stats').catch(() => null),
  ]);
  return { days: byHour.days, hours: byHour.hours, stats };
}
// Last N days of plant kWh totals. Today's row is computed live from agg_minute rather
// than the daily-synced cache (migration 0013); `expected` is that day's irradiance
// scaled by the fitted conversion ratio and drives the dotted line (migration 0014).
// It is absent, not zero, on days with no irradiance on file, so the line breaks.
async function fetchTrendDaily(days) {
  const api = await getJSON('/api/trends/daily?days=' + days);
  return api.rows || [];
}
async function fetchTrendMonthly() {
  const api = await getJSON('/api/trends/monthly');
  return api.rows || [];
}
// period-over-period totals for the Overview trend arrows ({today,week,month}:{cur,prev})
async function fetchCompare() {
  return getJSON('/api/trends/compare').catch(() => ({}));
}
// calibrated clear-sky potential profile for a date: { date, scaleW, points:[{t,w}] } (dotted chart line)
async function fetchPotential(date) {
  return getJSON('/api/trends/potential' + (date ? '?date=' + date : '')).catch(() => null);
}
// avg power per day-segment + load source split: { days, segments:[{seg,load_w,solar_w,batt_w,grid_w,mins}] }
// (replaced the removed "wasted solar" estimate — see server.js note)
async function fetchSegments(days) {
  return getJSON('/api/trends/segments?days=' + (days || 7)).catch(() => null);
}
// battery balance + health: { banks:[{sn,soc,voltage,current}], socSpread, vSpread, status (sustained 10min), pending, max24h, max72h, stale, tempC, hrsAtFullToday, tempHot }
async function fetchBalance() {
  return getJSON('/api/balance').catch(() => null);
}

// ---- me: plan, preferences, plants -----------------------------------------
// One call on load. `plants[].config` is plant_config (timezone, currency, tariff,
// battery, roof). `prefs` is the per-user display state that used to live in
// localStorage and therefore vanished on a new device.
async function fetchMe() {
  const { data, error } = await window.sb.rpc('api_me');
  if (error) throw new Error(error.message);
  return data || { plan: 'free', prefs: {}, plants: [] };
}
async function savePrefs(patch) {
  const { data, error } = await window.sb.rpc('api_prefs_set', { p_prefs: patch });
  if (error) throw new Error(error.message);
  return data || {};
}
async function savePlantConfig(plantId, patch) {
  const { data, error } = await window.sb.from('plant_config').update(patch).eq('plant_id', plantId).select().single();
  if (error) throw new Error(error.message);
  return data;
}
async function deleteAccount() {
  const { data, error } = await window.sb.rpc('api_account_delete');
  if (error) throw new Error(error.message);
  return data;
}

// What an empty chart should say. A plant with under a day of history is new, and
// "collecting your first day" is the honest message; anything older is a real gap.
function emptyText(days, fallback) {
  if (days != null && days < 1) return 'Collecting your first day of data — check back tomorrow.';
  if (days != null && days < 3) return 'Only ' + days + ' day' + (days === 1 ? '' : 's') + ' logged so far — this fills in as history builds.';
  return fallback || 'No data for this range yet.';
}

Object.assign(window, {
  fetchSnapshot, fetchDay, fetchEarliest, fetchEnergy, fetchHourly, fetchTrends, fetchTrendDaily, fetchTrendMonthly, fetchCompare, fetchPotential, fetchSegments, fetchBalance,
  fetchMe, savePrefs, savePlantConfig, deleteAccount, emptyText, BATT_MAX_KW, TYPICAL_DAYS,
});
