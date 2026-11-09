// ============================================================================
// data.jsx — LIVE data layer. Fetches the local Node server (server.js), which
// proxies SunSynk Connect, and maps the responses into the shapes the UI uses.
//   /api/overview          -> snapshot  { updated, plant, aggregate, inverters }
//   /api/history?date=     -> day series { points:[{t,pv,load,batt,grid,soc}], totals }
//   /api/energy?period=    -> days[]     [{ pv, load, imp, chg, dischg, selfSuff, ... }]
// (Field names mirror API.md; the old mock generators were removed.)
// ============================================================================

const TYPICAL_DAYS = 7; // Live "usually N%" and Battery's "if the grid goes off".
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
// The plant's timezone: every clock time on screen is the plant's, as alerts and emails are (SOLAR-445).
window.PLANT_TZ = window.PLANT_TZ || null;
window.setCurrentPlant = (id, currency, tz) => {
  window.CURRENT_PLANT = id == null ? null : Number(id);
  if (currency) window.PLANT_CURRENCY = currency;
  window.PLANT_TZ = tz || null;
};

const ROUTES = {
  '/api/overview':         () => ['api_overview', {}],
  '/api/history':          (q) => ['api_history', { p_date: q.date || null }],
  '/api/history/earliest': () => ['api_history_earliest', {}],
  '/api/data/days':        () => ['api_data_days', {}],
  '/api/history/inverters': (q) => ['api_inverter_history', { p_date: q.date || null }],
  '/api/strings/health':    () => ['api_string_health', {}],
  '/api/grid/today':        (q) => ['api_grid_today', { p_date: q.date || null }],
  '/api/energy':           (q) => ['api_energy', { p_period: q.period || 'week' }],
  '/api/plant/days':       () => ['api_plant_days', {}],
  '/api/trends/by-hour':   (q) => ['api_trends_by_hour', { p_days: Number(q.days) || 14 }],
  '/api/trends/daily':     (q) => ['api_trends_daily', { p_days: Number(q.days) || 30 }],
  '/api/trends/compare':   () => ['api_trends_compare', {}],
  '/api/health':           () => ['api_health', {}],
};

async function getJSON(url) {
  const [path, qs] = String(url).split('?');
  const q = Object.fromEntries(new URLSearchParams(qs || ''));

  const route = ROUTES[path];
  if (!route) throw new Error('No RPC mapped for ' + path);

  const [fn, params] = route(q);
  return must(window.sb.rpc(fn, { ...params, p_plant: window.CURRENT_PLANT }), {}, 'RPC ' + fn + ' failed');
}
// A Supabase call's data, or its error thrown. fallback stands in for no data.
// The error also goes to PostHog, since many callers fall back to empty data without a
// word (SOLAR-243). Not reported: no connection, and a change the database refused on
// purpose (22023), which the caller explains.
async function must(call, fallback, failed = 'failed') {
  const { data, error } = await call;
  if (error) {
    const e = new Error(error.message || failed);
    if (error.code !== '22023' && !/fetch|network|load failed/i.test(e.message)) window.reportClientError?.(e);
    throw e;
  }
  return fallback !== undefined && !data ? fallback : data;
}

// One answer per plant shared by every caller for `ms`, so pages opened one after another
// do not each ask again (SOLAR-140). `rk` is App's refreshKey: a manual refresh or a plant
// switch bumps it, and a caller holding a newer one asks afresh. A failure is not kept.
const shared = {};
function sharedAsk(name, ms, rk, ask) {
  const k = name + ':' + window.CURRENT_PLANT;
  const m = shared[k];
  if (m && m.rk >= (rk || 0) && Date.now() - m.at < ms) return m.p;
  const p = ask().catch((e) => { if (shared[k] && shared[k].p === p) delete shared[k]; throw e; });
  shared[k] = { at: Date.now(), rk: rk || 0, p };
  return p;
}
// The plant and the shared answers belong to who was signed in. Without a reload the next
// user's first loads asked for the last user's plant and got 403s (SOLAR-442).
window.sb.auth.onAuthStateChange((event) => {
  if (event !== 'SIGNED_OUT') return;
  window.CURRENT_PLANT = null; window.PLANT_CURRENCY = 'ZAR'; window.PLANT_TZ = null;
  for (const k in shared) delete shared[k];
});
const MIN5 = 5 * 60000;

const isOnline = (s) => s === 1 || s === '1' || s === 'online' || s === true;

// SunSynk's flag can read 0 for hours while the inverter still uploads (SOLAR-226), so
// a reading newer than this counts as online. A slave uploads every 5 min; 15 allows
// two missed uploads. The flag decides only when there is no reading time.
const READ_FRESH_MS = 15 * 60000;

// ---- /api/overview -> snapshot ---------------------------------------------
function mapInverter(s, asOf) {
  const out = {
    sn: s.sn,
    alias: s.alias || s.sn,
    model: s.model || '—',
    status: (s.readAt ? asOf - s.readAt * 1000 <= READ_FRESH_MS : isOnline(s.status)) ? 'online' : 'offline',
    soft: s.soft || '—',
    hmi: s.hmi || '—',
    gsn: s.gsn || '—',
    commissioned: s.commType || '—', // no commissioning date in the API; show link type
    readAt: s.readAt ? s.readAt * 1000 : null, // when this inverter took its reading (ms)
    pvNow: s.pv.power,
    pvToday: s.pv.today,
    pvTotal: s.pv.total,
    output: s.output.power,
    battPower: s.battery.power,
    // signed, + = powering the house (stored readings are + = charging)
    battOut: s.battery.signedPower == null ? null : -s.battery.signedPower,
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
    gridToToday: s.grid.todayExport,
    gridToTotal: s.grid.totalExport,
    gridVolt: s.grid.voltage ?? null,
    gridVolts: s.grid.voltages || [],          // one per phase this inverter reports
    gridRelay: s.grid.relay ?? null,
    bank2: s.battery.bank2 || null,            // second battery bank, when the firmware has one
    gridFreq: s.grid.frequency || s.output.frequency || 0,
    gridPf: s.grid.powerFactor || 0,
    load: s.load.power,
    loadToday: s.load.today,
    loadTotal: s.load.total,
    loadFreq: s.load.frequency || s.output.frequency || 0,
    strings: (s.pv.strings || []).map((st, i) => ({
      no: st.no || i + 1, v: st.voltage, i: st.current, p: st.power, today: st.today,
    })),
    // inputs the inverter reports that have never produced; their rows are not stored (0061)
    unusedInputs: Math.max(0, (s.pv.stringSlots || 0) - (s.pv.strings || []).length),
    phases: (s.output.voltages && s.output.voltages.length ? s.output.voltages : [s.output.voltage])
      .map((v, i, arr) => ({ volt: v, current: v ? (s.output.power / arr.length) / v : 0, power: s.output.power / arr.length })),
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
    // null when no inverter's battery answered this minute (stored as unknown, SOLAR-231)
    battSoc: totals.soc != null ? totals.soc
      : invs.some((x) => x.battSoc != null) ? Math.round(sum((x) => x.battSoc) / invs.filter((x) => x.battSoc != null).length) : null,
    battPower: totals.batteryPower != null ? totals.batteryPower : sum((x) => x.battPower),
    // signed, + = powering the house; nets a charging inverter against a discharging one
    battOut: totals.batteryPower != null ? (totals.batteryDirection === 'charging' ? -totals.batteryPower : totals.batteryPower) : sum((x) => x.battOut),
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
    gridToToday: r1(totals.todayGridExport != null ? totals.todayGridExport : sum((x) => x.gridToToday)),
    gridToTotal: r1(sum((x) => x.gridToTotal)),
    phaseDown: !!totals.phaseDown,
    gridFreq: gf ? gf.gridFreq : (invs[0] ? invs[0].gridFreq : 0),
    gridPf: invs[0] ? invs[0].gridPf : 0,
    loadNow: totals.load != null ? totals.load : sum((x) => x.load),
    loadToday: r1(sum((x) => x.loadToday)),
    loadTotal: r1(sum((x) => x.loadTotal)),
  };
}

async function fetchSnapshot() {
  // lastTs is the poller's last reading time (0088; it used to take a second call to
  // api_health); generatedAt only stamps the answer. The header shows the former so a
  // stalled poller is visible.
  const api = await getJSON('/api/overview');
  const asOf = api.generatedAt ? new Date(api.generatedAt).getTime() : Date.now();
  const inverters = (api.inverters || []).map(s => mapInverter(s, asOf));
  // Battery capacity and reserve are not derived here (SunSynk under-reports Ah/V) —
  // they come from app_config via api_overview, which is also what the phone alerts
  // read. Pass them straight through; null until the first snapshot lands.
  if (api.config && api.config.currency) window.PLANT_CURRENCY = api.config.currency;
  const cfg = api.config || {};
  const agg = aggregate(inverters, api.totals || {});
  // Today's counters are the last reading's. A plant silent since before the plant's
  // midnight has none for today, not yesterday's (SOLAR-348).
  const day = (d) => { try { return new Intl.DateTimeFormat('en-CA', { timeZone: cfg.timezone || undefined }).format(d); } catch (e) { return null; } };
  if (api.lastTs && day(new Date(api.lastTs * 1000)) !== day(new Date()))
    ['pvToday', 'loadToday', 'gridFromToday', 'gridToToday', 'battChgToday', 'battDischgToday'].forEach(k => { agg[k] = null; });
  return {
    updated: new Date(api.generatedAt || Date.now()),
    lastReading: api.lastTs ? new Date(api.lastTs * 1000) : null,
    plant: api.plant || { id: null, name: 'My plant' },
    aggregate: agg,
    config: api.config || null,
    // Fresh-link sync (0048): pending flags, bookmarks, days of the last 60 with a chart.
    sync: api.sync || null,
    // What this plant has. null (not decided yet) shows everything; false hides it.
    // A battery not decided yet shows only once a charge reads, as detection counts one
    // (0088): a home with none read as a dead battery at 0 W (SOLAR-348).
    features: {
      hasBattery: cfg.hasBattery === true || (cfg.hasBattery == null && agg.battSoc > 0),
      // Mains live right now beats the off-grid flag, which the poller only re-decides
      // every 10 min; until then a grid switched back on would still read Off-grid (SOLAR-7).
      hasGrid: cfg.hasGrid !== false || (api.totals || {}).gridPresent === true,
      decided: cfg.featuresSource != null && cfg.featuresSource !== 'default',
      banks: cfg.batteryBanks || 'per-inverter',
    },
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
    recoveredMinutes: api.recoveredMinutes || 0, // minutes recovered from SunSynk's cloud
    totals: {
      pv: +pvK.toFixed(1), load: +loadK.toFixed(1),
      chg: +chg.toFixed(1), dischg: +dischg.toFixed(1), imp: +imp.toFixed(1),
    },
  };
}

// Earliest date with data (≈ commission date). Bounds the day picker; null if
// unknown (treated as "no lower limit" by the UI).
// The days that have any data, as a Set of 'YYYY-MM-DD', for the calendar pop-up (0080).
// One ask per plant, shared by every date bar. `fresh` asks again (the calendar opening);
// while history is still being fetched a saved list is old after a minute, as the import
// adds days (SOLAR-175). A failed ask keeps the last good list; null only before any came.
const dataDaysCache = {}, dataDaysGood = {};
function fetchDataDays(fresh) {
  // No plant yet (the empty outlines in Setup): no days to ask about, and the ask would fail.
  if (window.CURRENT_PLANT == null) return Promise.resolve(null);
  const k = window.CURRENT_PLANT, c = dataDaysCache[k], s = window.SYNC;
  const old = c && s && (s.pending || s.spinePending) && Date.now() - c.at > 60000;
  if (!c || fresh || old) {
    const p = getJSON('/api/data/days')
      .then(d => (dataDaysGood[k] = new Set(Array.isArray(d) ? d : [])))
      .catch(() => { if (dataDaysCache[k]?.p === p) delete dataDaysCache[k]; return dataDaysGood[k] ?? null; });
    dataDaysCache[k] = { p, at: Date.now() };
  }
  return dataDaysCache[k].p;
}

async function fetchEarliest() {
  // No plant yet (the empty outlines in Setup): there is no first day to ask about.
  if (window.CURRENT_PLANT == null) return null;
  // The first day does not move: one ask per plant and page load. An unknown one is asked again.
  try { return await sharedAsk('earliest', Infinity, 0, () => getJSON('/api/history/earliest').then((api) => api.earliest || Promise.reject(new Error('none')))); }
  catch (e) { return null; }
}

// ---- /api/history/inverters -> per-inverter history, 288 buckets -------------
// AC/DC temperature, AC terminal voltage (min/max/last), AC and grid frequency
// (min/max) per 5-minute bucket. History-only (SunSynk output/day + grid/day,
// fetched by recover every 6 h), so it lags the live numbers; `last` on each
// inverter is the latest bucket with data.
// Equipment draws two charts from one answer, and Grid's outages read it too.
async function fetchInverterHistory(date, rk) {
  const api = await sharedAsk('invhist:' + (date || ''), MIN5, rk, () => getJSON('/api/history/inverters' + (date ? '?date=' + date : '')));
  return api.inverters || [];
}

// ---- /api/energy -> daily/monthly aggregate rows ---------------------------
async function fetchEnergy(period) {
  const api = await getJSON('/api/energy?period=' + period);
  return api.rows || [];
}

// ---- /api/trends -> hour-of-day profile from the local log -----------------
// The profile barely moves within the hour; Live asks again when it opens.
async function fetchHourly(days, rk) {
  const n = days || TYPICAL_DAYS;
  const byHour = await sharedAsk('hourly:' + n, 60 * 60000, rk, () => getJSON('/api/trends/by-hour?days=' + n));
  return { days: byHour.days || n, hours: byHour.hours || [] };
}
// Each of the caller's plants: last reading, inverters online, first-load progress (0101).
// For the plant menu; no p_plant, so not through getJSON.
async function fetchPlantStates() {
  return must(window.sb.rpc('api_plant_states'), [], 'RPC api_plant_states failed');
}
// How many days this plant has logged; drives the "collecting your first day" copy.
async function fetchPlantDays() {
  const api = await getJSON('/api/plant/days');
  return api.days ?? null;
}
// Last N days of plant kWh totals. Today's row is computed live from agg_minute rather
// than the daily-synced cache (migration 0013); `expected` is that day's irradiance
// scaled by the fitted conversion ratio and drives the dotted line (migration 0014).
// It is absent, not zero, on days with no irradiance on file, so the line breaks.
async function fetchTrendDaily(days, rk) {
  const api = await sharedAsk('daily:' + days, MIN5, rk, () => getJSON('/api/trends/daily?days=' + days));
  return api.rows || [];
}
// period-over-period totals for the Overview trend arrows ({today,week,month}:{cur,prev})
async function fetchCompare(rk) {
  return sharedAsk('compare', MIN5, rk, () => getJSON('/api/trends/compare')).catch(() => ({}));
}
// each used string's kWh today and its usual share by this time of day (0076, SOLAR-51)
async function fetchStringHealth() {
  return getJSON('/api/strings/health');
}
// a day's grid from our own minute readings, SunSynk's history filling their gaps: volts and off
// per 5-minute step, off minutes (0159, SOLAR-398, 0166). date: a past day; none is today.
// Shared: Equipment's Grid tile and the Grid tab's day chart ask for the same answer (SOLAR-421).
async function fetchGridToday(rk, date) {
  return sharedAsk('gridtoday:' + (date || ''), MIN5, rk, () => getJSON('/api/grid/today' + (date ? '?date=' + date : '')));
}

// ---- me: plan, preferences, plants -----------------------------------------
// One call on load. `plants[].config` is plant_config (timezone, currency, tariff,
// battery, roof). `prefs` is the per-user display state that used to live in
// localStorage and therefore vanished on a new device.
async function fetchMe() {
  return must(window.sb.rpc('api_me'), { plan: 'free', freeWeekEndsAt: null, prefs: {}, plants: [] });
}
async function savePrefs(patch) {
  return must(window.sb.rpc('api_prefs_set', { p_prefs: patch }), {});
}
async function savePlantConfig(plantId, patch) {
  const data = await must(window.sb.from('plant_config').update(patch).eq('plant_id', plantId).select().single());
  window.track('plant_settings_save_done', { fields: Object.keys(patch) });
  return data;
}
// A user's on/off switches in table, one column per kind. No row yet means all on.
const fetchFlags = (table, kinds, userId) => must(window.sb.from(table).select(kinds.join(',')).eq('user_id', userId).maybeSingle(),
  Object.fromEntries(kinds.map(k => [k, true])));
// One kind per call, so two quick taps on different rows can't undo each other.
async function saveFlag(table, event, userId, kind, on) {
  await must(window.sb.from(table).upsert({ user_id: userId, [kind]: on }));
  window.track(event, { kind, on });
}
// Which report and alert emails the user wants (0091, SOLAR-158).
const EMAIL_KINDS = ['weekly', 'monthly', 'yearly', 'grid', 'battery', 'panels', 'readings', 'sunsynk'];
const fetchEmailPrefs = (userId) => fetchFlags('email_prefs', EMAIL_KINDS, userId);
const saveEmailPref = (userId, kind, on) => saveFlag('email_prefs', 'email_pref_change_done', userId, kind, on);
// The alerts of the last 30 days, {pinned, items, unread} (0124, SOLAR-244).
// The bell: the billing notices, and the last 30 days of alerts as the full page lists them
// (SOLAR-411): a start and its "back" are two rows (0166, SOLAR-431). unread counts rows.
async function fetchNotifications() {
  const [n, a] = await Promise.all([must(window.sb.rpc('api_notifications')),
    fetchAlerts({ from: new Date(Date.now() - 30 * 86400000) })]);
  return { pinned: n.pinned, items: a.items, unread: a.items.filter(it => !it.read).length };
}
// Every alert, one row each, a "back" too (0166, SOLAR-431): {items, more,
// unread}. from: a Date or null; kind: an alert switch or null; before: the last item shown.
async function fetchAlerts({ from, kind, unread, before }) {
  return must(window.sb.rpc('api_alerts', { p_from: from ? from.toISOString() : null, p_switch: kind || null,
    p_unread: !!unread, p_before: before ? before.id : null, p_before_ts: before ? before.ts : null }));
}
// null marks every one read.
async function readNotifications(ids) {
  await must(window.sb.rpc('api_notifications_read', { p_ids: ids }));
}
// Which alerts pop up (push_prefs, 0124).
const PUSH_KINDS = ['grid', 'battery', 'panels', 'readings', 'sunsynk'];
const fetchPushPrefs = (userId) => fetchFlags('push_prefs', PUSH_KINDS, userId);
const savePushPref = (userId, kind, on) => saveFlag('push_prefs', 'push_pref_change_done', userId, kind, on);

// Pop-ups on this browser. 'ok' where it can; 'ios' on an iPhone or iPad outside the
// Home Screen app (Safari has no push there); 'none' elsewhere.
function pushSupport() {
  if ('serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window) return 'ok';
  const ios = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  return ios ? 'ios' : 'none';
}
async function pushSub() {
  const reg = await navigator.serviceWorker.getRegistration('/');
  return reg ? reg.pushManager.getSubscription() : null;
}
// 'on' | 'off' | 'blocked' | 'ios' | 'none'
async function pushState() {
  const s = pushSupport();
  if (s !== 'ok') return s;
  if (Notification.permission === 'denied') return 'blocked';
  return (await pushSub()) ? 'on' : 'off';
}
// The switch is the ask: the browser's own prompt shows only now, never on load.
async function pushTurnOn() {
  const perm = await Notification.requestPermission();
  if (perm !== 'granted') return perm === 'denied' ? 'blocked' : 'off';
  const reg = await navigator.serviceWorker.register('/sw.js');
  await navigator.serviceWorker.ready;
  const key = Uint8Array.from(atob(window.VAPID_PUBLIC.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
  const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
  const j = sub.toJSON();
  const { error } = await window.sb.rpc('api_push_sub', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth });
  if (error) { await sub.unsubscribe().catch(() => {}); throw new Error(error.message); }
  window.track('push_enabled_done');
  return 'on';
}
// On load: a browser with pop-ups on sends its address again, so it follows whoever is
// signed in now (a session that ended without Sign out left it with the last account).
async function pushResync() {
  if (pushSupport() !== 'ok' || Notification.permission !== 'granted') return;
  const sub = await pushSub();
  if (!sub) return;
  const j = sub.toJSON();
  await window.sb.rpc('api_push_sub', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth });
}
// Off here, and on sign-out, so a shared computer stops showing the last account's alerts.
// The browser's own subscription goes even if the server call fails: the push service
// then answers "gone" and notify deletes the row.
async function pushTurnOff(reason = 'switch') {
  if (pushSupport() !== 'ok') return 'off';
  const sub = await pushSub();
  if (!sub) return 'off';
  // a supabase query has then but no catch
  try { await window.sb.rpc('api_push_unsub', { p_endpoint: sub.endpoint }); } catch (e) { /* see above */ }
  await sub.unsubscribe();
  window.track('push_disabled_done', { reason });
  return 'off';
}
async function deleteAccount() {
  const data = await must(window.sb.rpc('api_account_delete'));
  window.track('account_delete_done');
  return data;
}

// How far a first load has got, 0..1, or null when nothing is loading (SOLAR-176).
// Minute days and temperature days of the last 60 count together, since the 60-days
// email waits for both. Temperatures count only while more than a day behind: every
// plant falls one day behind at midnight (as first-load-continue, 0093).
// Temperatures behind are a first load only for a plant linked in the last day. On an
// older plant they are the walk catching up after a dead login, not a plant setting up
// (SOLAR-373). A restarted plant (0125) still loads its minutes as a first load.
function firstLoadSync(sync, linkedAt) {
  if (!sync || !sync.invPending || sync.spinePending) return sync;
  if (!linkedAt || Date.now() - Date.parse(linkedAt) < 86400000) return sync;
  return { ...sync, pending: false, invPending: false };
}
function syncProgress(sync) {
  if (!sync || !sync.pending) return null;
  const win = sync.window || 60;
  const days = Math.min(win, sync.days || 0);
  const behind = sync.invPending && sync.tempNext
    ? Math.round((Date.parse(window.localDateStr()) - Date.parse(sync.tempNext)) / 86400000) : 0;
  const tempDays = behind > 1 ? Math.max(0, win - behind) : win;
  return days < win || tempDays < win ? (days + tempDays) / (2 * win) : null;
}

// What an empty chart should say. A plant with under a day of history is new, and
// "collecting your first day" is the honest message; anything older is a real gap.
// While the last 60 days are still being fetched (window.SYNC, from the snapshot)
// a thin log is not a gap either, and says so.
function emptyText(days, fallback) {
  const sync = window.SYNC;
  const fetching = !!(sync && sync.pending && sync.days < sync.window);
  if (days != null && days < 1) return fetching
    ? 'Loading the last 60 days.'
    : 'Collecting your first day. Check back tomorrow.';
  if (fetching) return (days != null ? days + ' day' + (days === 1 ? '' : 's') + ' so far. ' : '')
    + 'Loading the last 60 days.';
  if (days != null && days < 3) return days + ' day' + (days === 1 ? '' : 's') + ' so far. This fills in as history builds.';
  return fallback || 'No data for this range yet.';
}

Object.assign(window, {
  fetchSnapshot, fetchDay, fetchEarliest, fetchDataDays, fetchInverterHistory, fetchEnergy, fetchHourly, fetchPlantDays, fetchPlantStates, fetchTrendDaily, fetchCompare, fetchStringHealth, fetchGridToday,
  fetchMe, savePrefs, savePlantConfig, fetchEmailPrefs, saveEmailPref, deleteAccount,
  fetchNotifications, readNotifications, fetchPushPrefs, savePushPref, EMAIL_KINDS, PUSH_KINDS, pushSupport, pushState, pushTurnOn, pushTurnOff, pushResync, emptyText, syncProgress, firstLoadSync, BATT_MAX_KW, TYPICAL_DAYS,
});
