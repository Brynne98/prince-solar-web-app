#!/usr/bin/env node
// Mock of openapi.sunsynk.net for local development and the readiness tests.
//
// Serves the endpoints the Edge Functions call, for several pretend SunSynk logins,
// each with a different plant shape (see PLANTS / ACCOUNTS below). Values follow a
// simple daily simulation in the plant's own timezone: a clear-sky bell for PV, a
// household load profile, a battery that soaks up surplus and covers the evening,
// and the grid taking whatever is left. Deterministic for a given minute, so two
// polls in the same minute agree and history endpoints reproduce the same day.
//
// No signing, no real auth: any password works, the bearer token is the username.
//
//   node scripts/mock-sunsynk/server.js            # listens on :4400
//   SUNSYNK_API_BASE=http://host.docker.internal:4400 for the local edge runtime
//
// Nothing here is used in production.
const http = require("node:http");

const PORT = Number(process.env.PORT) || 4400;

// ---------------------------------------------------------------------------
// Plant shapes
// ---------------------------------------------------------------------------
// gridMode: 'import' (no export allowed), 'export' (surplus sold), 'off' (no grid at all)
// battSign: what a POSITIVE battery `power` means on this firmware
// banks: 'per-inverter' | 'shared' (one pack, every inverter reads the same BMS)
// upload: seconds between datalogger uploads (device_time only advances then)
const PLANTS = {
  5001: {
    name: "Prince home", tz: "Africa/Johannesburg", currency: "ZAR", lat: -26.2041, lon: 28.0473,
    kwp: 12.6, battKwh: 26.5, gridMode: "import", phases: 1, battSign: "discharging", banks: "per-inverter",
    loadBase: 900, inverters: [
      { sn: "M5001A", alias: "Master", share: 0.5, upload: 60, ct: true, model: "SUNSYNK-8K-SG01LP1" },
      { sn: "S5001B", alias: "Slave", share: 0.5, upload: 300, ct: false, model: "SUNSYNK-8K-SG01LP1" },
    ],
  },
  // Lower id than 5001 on purpose: commissioned earlier at SunSynk.
  3001: {
    name: "Old exporter", tz: "Europe/London", currency: "GBP", lat: 51.5, lon: -0.12,
    kwp: 8, battKwh: 10, gridMode: "export", phases: 3, battSign: "charging", banks: "per-inverter",
    loadBase: 500, inverters: [
      { sn: "E3001A", alias: "Garage", share: 1, upload: 60, ct: true, model: "SUNSYNK-12K-SG04LP3" },
    ],
  },
  6002: {
    name: "Cabin", tz: "Africa/Windhoek", currency: "NAD", lat: -22.56, lon: 17.08,
    kwp: 4, battKwh: 10, gridMode: "off", phases: 1, battSign: "discharging", banks: "per-inverter",
    loadBase: 300, inverters: [
      { sn: "C6002A", alias: "Cabin", share: 1, upload: 60, ct: false, model: "SUNSYNK-5K-SG04LP1" },
    ],
  },
  6003: {
    name: "Grid-tied", tz: "Australia/Sydney", currency: "AUD", lat: -33.87, lon: 151.21,
    kwp: 6.6, battKwh: 0, gridMode: "export", phases: 1, battSign: "discharging", banks: "per-inverter",
    loadBase: 600, inverters: [
      { sn: "G6003A", alias: "Roof", share: 1, upload: 60, ct: true, model: "SUNSYNK-6K-SG03LP1" },
    ],
  },
  6004: {
    name: "Shared bank", tz: "Africa/Johannesburg", currency: "ZAR", lat: -33.93, lon: 18.42,
    kwp: 16, battKwh: 30, gridMode: "import", phases: 1, battSign: "discharging", banks: "shared", secondBank: true,
    loadBase: 1200, inverters: [
      { sn: "M6004A", alias: "Inverter 1", share: 0.5, upload: 60, ct: true, model: "SUNSYNK-8K-SG01LP1" },
      { sn: "S6004B", alias: "Inverter 2", share: 0.5, upload: 60, ct: true, model: "SUNSYNK-8K-SG01LP1" },
    ],
  },
};

// SunSynk logins. pageSize forces pagination for the accounts that carry it.
const ACCOUNTS = {
  "brynne@mock": { plants: [5001] },
  "family@mock": { plants: [5001] },              // same plant shared to a second login
  "export@mock": { plants: [3001, 6002], pageSize: 1 },
  "nobatt@mock": { plants: [6003] },
  "shared@mock": { plants: [6004] },
};

// ---------------------------------------------------------------------------
// Time helpers
// ---------------------------------------------------------------------------
function localParts(tz, d = new Date()) {
  const p = new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  }).formatToParts(d);
  const g = (t) => Number(p.find((x) => x.type === t).value);
  return { y: g("year"), m: g("month"), d: g("day"), hh: g("hour") % 24, mm: g("minute"), ss: g("second") };
}
const ymd = (p) => `${p.y}-${String(p.m).padStart(2, "0")}-${String(p.d).padStart(2, "0")}`;
const hms = (p) => `${String(p.hh).padStart(2, "0")}:${String(p.mm).padStart(2, "0")}:${String(p.ss).padStart(2, "0")}`;

/** 0..1 cloudiness for a day, stable per date so history reproduces. */
function cloudFactor(day) {
  let h = 0;
  for (const c of day) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return 0.6 + ((h % 40) / 100); // 0.6 .. 0.99
}

// ---------------------------------------------------------------------------
// The daily simulation: minute-by-minute from midnight to `uptoMin`, plant-wide.
// ---------------------------------------------------------------------------
function simulateDay(plant, day, uptoMin) {
  const cloud = cloudFactor(day);
  const reserve = 20;
  let soc = plant.battKwh > 0 ? 55 : 0;
  const rows = [];
  const tot = { pv: 0, load: 0, imp: 0, exp: 0, chg: 0, dischg: 0 };
  for (let m = 0; m <= uptoMin; m++) {
    const h = m / 60;
    const sun = Math.max(0, Math.sin(Math.PI * (h - 6) / 12.5));       // 06:00 .. 18:30
    const pv = plant.kwp * 1000 * 0.85 * cloud * sun * sun;
    let load = plant.loadBase;
    if (h >= 6 && h < 8) load += 1500;                                   // morning
    if (h >= 18 && h < 21.5) load += 2200;                               // evening
    if (h >= 12 && h < 13) load += 600;
    let batt = 0, grid = 0;
    let surplus = pv - load;
    if (plant.battKwh > 0) {
      const maxW = plant.battKwh * 250;                                  // ~C/4
      if (surplus > 0 && soc < 100) batt = Math.min(surplus, maxW);      // + = charging
      else if (surplus < 0 && soc > reserve) batt = Math.max(surplus, -maxW);
      soc += (batt / 60 / 1000) / plant.battKwh * 100;
      soc = Math.max(0, Math.min(100, soc));
      surplus -= batt;
    }
    if (plant.gridMode === "off") grid = 0;                              // surplus curtailed, deficit = brownout (ignored)
    else if (plant.gridMode === "export") grid = -surplus;               // + import / - export
    else grid = surplus < 0 ? -surplus : 0;                              // import only; surplus curtailed
    const pvEff = plant.gridMode === "off" || plant.gridMode === "import" ? Math.min(pv, load + Math.max(0, batt)) : pv;
    rows.push({ m, pv: pvEff, load, batt, grid, soc });
    tot.pv += pvEff / 60000; tot.load += load / 60000;
    if (grid > 0) tot.imp += grid / 60000; else tot.exp += -grid / 60000;
    if (batt > 0) tot.chg += batt / 60000; else tot.dischg += -batt / 60000;
  }
  return { rows, tot, cloud };
}

/** Plant state at `now` plus per-inverter split. */
function plantNow(plant, now = new Date()) {
  const p = localParts(plant.tz, now);
  const minute = p.hh * 60 + p.mm;
  const sim = simulateDay(plant, ymd(p), minute);
  const r = sim.rows[minute];
  return { p, minute, sim, r };
}

const r1 = (v) => Math.round(v * 10) / 10;
const r2 = (v) => Math.round(v * 100) / 100;

/** Datalogger time for an inverter: floors to its upload cadence. */
function deviceTime(plant, inv, now) {
  const step = inv.upload * 1000;
  return hms(localParts(plant.tz, new Date(Math.floor(now.getTime() / step) * step)));
}

function inverterRealtime(plantId, inv, now = new Date()) {
  const plant = PLANTS[plantId];
  // Sample at the inverter's last upload instant, so a slow logger repeats itself.
  const step = inv.upload * 1000;
  const at = new Date(Math.floor(now.getTime() / step) * step);
  const { p, r, sim } = plantNow(plant, at);
  const dayStr = ymd(p);
  const time = `${dayStr} ${hms(p)}`;
  const s = inv.share;
  const pv = r.pv * s, load = r.load * s, batt = r.batt * s;
  // Grid: only CT-bearing inverters see it; they share it equally.
  const ctCount = plant.inverters.filter((i) => i.ct).length || 1;
  const grid = inv.ct ? r.grid / ctCount : 0;
  const hasBatt = plant.battKwh > 0;
  const sign = plant.battSign === "charging" ? 1 : -1;               // firmware's sign for + charging
  const battPowerRaw = hasBatt ? Math.round(batt * sign) : 0;
  const vBatt = hasBatt ? 48 + (r.soc / 100) * 5 : 0;
  const nStrings = 2;
  const strings = Array.from({ length: nStrings }, (_, k) => {
    const ppv = pv / nStrings;
    const vpv = ppv > 5 ? 320 + k * 10 : 1.2;
    return { pvNo: k + 1, vpv: r1(vpv), ipv: r2(ppv > 5 ? ppv / vpv : 0), ppv: Math.round(ppv), todayPv: r1(sim.tot.pv * s / nStrings), sn: inv.sn, time };
  });
  const phaseVolt = plant.gridMode === "off" ? null : 230 + (p.mm % 7) - 3;
  const phases = plant.phases;
  const vip = (power, volt) => Array.from({ length: phases }, (_, i) => ({
    volt: volt == null ? null : r1(volt + i * 1.5), current: volt ? r2(power / phases / volt) : 0, power: Math.round(power / phases),
  }));
  const gridPayload = {
    pac: Math.round(grid), fac: plant.gridMode === "off" ? 0 : 50.0, pf: 0.98, qac: 0,
    etodayFrom: r1(sim.tot.imp / ctCount), etodayTo: r1(sim.tot.exp / ctCount),
    etotalFrom: r1(4200 + sim.tot.imp / ctCount), etotalTo: r1(plant.gridMode === "export" ? 1800 + sim.tot.exp : 0),
    acRealyStatus: plant.gridMode === "off" ? "0" : "1", status: plant.gridMode === "off" ? 0 : 1,
  };
  if (plant.gridMode !== "off") gridPayload.vip = vip(grid, phaseVolt);
  const batteryPayload = hasBatt ? {
    power: battPowerRaw, soc: Math.round(r.soc), voltage: r1(vBatt), current: r1(battPowerRaw / vBatt), temp: 27 + (p.hh > 12 ? 3 : 0),
    capacity: Math.round(plant.battKwh * 1000 / 51.2 / (plant.banks === "shared" ? 1 : plant.inverters.length)), numberOfBatteries: plant.banks === "shared" ? 6 : 3,
    etodayChg: r1(sim.tot.chg * s), etodayDischg: r1(sim.tot.dischg * s), etotalChg: r1(3100 + sim.tot.chg * s), etotalDischg: r1(2900 + sim.tot.dischg * s),
    type: "Lithium", status: batt > 5 ? 1 : batt < -5 ? 2 : 0,
  } : { power: 0, soc: 0, voltage: 0, current: 0, temp: -100, capacity: 0, numberOfBatteries: 0, etodayChg: 0, etodayDischg: 0, etotalChg: 0, etotalDischg: 0, type: "", status: 0 };
  if (hasBatt && plant.secondBank && inv === plant.inverters[0]) {
    batteryPayload.soc2 = Math.max(0, Math.round(r.soc) - 2); batteryPayload.voltage2 = r1(vBatt - 0.3);
    batteryPayload.current2 = r1(battPowerRaw / vBatt / 2); batteryPayload.power2 = Math.round(battPowerRaw / 2); batteryPayload.temp2 = 26;
  }
  return {
    input: { pac: Math.round(pv), etoday: r1(sim.tot.pv * s), etotal: r1(9800 + sim.tot.pv * s), pvIV: strings, mpptIV: [] },
    grid: gridPayload,
    battery: batteryPayload,
    load: { totalPower: Math.round(load), dailyUsed: r1(sim.tot.load * s), totalUsed: r1(12000 + sim.tot.load * s), loadFac: 50.0, vip: vip(load, 230), upsPowerL1: Math.round(load) },
    output: { pac: Math.round(load + Math.max(0, -grid)), pInv: Math.round(pv), fac: 50.0, vip: vip(load, 230) },
    deviceTime: time,
  };
}

// ---------------------------------------------------------------------------
// History endpoints
// ---------------------------------------------------------------------------
function feedRecords(plant, day, key, stepMin = 5, fmt = "hm") {
  const p = localParts(plant.tz);
  const isToday = day === ymd(p);
  const upto = isToday ? p.hh * 60 + p.mm : 1439;
  const sim = simulateDay(plant, day, upto);
  const out = [];
  for (let m = 0; m <= upto; m += stepMin) {
    const r = sim.rows[m];
    const v = key === "pv" ? r.pv : key === "load" ? r.load : key === "batt" ? -r.batt : key === "grid" ? r.grid : r.soc;
    const hh = String(Math.floor(m / 60)).padStart(2, "0"), mm = String(m % 60).padStart(2, "0");
    out.push({ time: fmt === "hm" ? `${hh}:${mm}` : `${day} ${hh}:${mm}:00`, value: String(Math.round(v)) });
  }
  return out;
}
/** Days the cloud "still has": last 10 days only, like the real feed. */
function feedHasDay(plant, day) {
  const p = localParts(plant.tz);
  const today = Date.UTC(p.y, p.m - 1, p.d);
  const [y, m, d] = day.split("-").map(Number);
  const diff = (today - Date.UTC(y, m - 1, d)) / 86400000;
  return diff >= 0 && diff <= 10;
}
function plantDayFeed(plant, day) {
  if (!feedHasDay(plant, day)) return { infos: [] };
  return { infos: [
    { label: "PV", unit: "W", records: feedRecords(plant, day, "pv") },
    { label: "Battery", unit: "W", records: feedRecords(plant, day, "batt") },
    { label: "SOC", unit: "%", records: feedRecords(plant, day, "soc") },
    { label: "Load", unit: "W", records: feedRecords(plant, day, "load") },
    { label: "Grid", unit: "W", records: feedRecords(plant, day, "grid") },
  ] };
}
const COMMISSIONED = "2025-11-03";
function dayTotals(plant, day) {
  if (day < COMMISSIONED) return null;
  const sim = simulateDay(plant, day, 1439);
  return sim.tot;
}
function monthFeed(plant, ym) {
  const [y, m] = ym.split("-").map(Number);
  const days = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const p = localParts(plant.tz);
  const rec = { pv: [], load: [], imp: [], exp: [], chg: [], dischg: [] };
  for (let d = 1; d <= days; d++) {
    const day = `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
    if (day > ymd(p)) break;
    const t = dayTotals(plant, day);
    if (!t) continue;
    for (const k of Object.keys(rec)) rec[k].push({ time: day, value: r1(t[k]).toString() });
  }
  return { infos: [
    { label: "PV", records: rec.pv }, { label: "Load", records: rec.load },
    { label: "Purchased", records: rec.imp }, { label: "Sold", records: rec.exp },
    { label: "Charge", records: rec.chg }, { label: "Discharge", records: rec.dischg },
  ] };
}
function yearFeed(plant, y) {
  const p = localParts(plant.tz);
  const rec = { pv: [], load: [], imp: [], exp: [], chg: [], dischg: [] };
  for (let m = 1; m <= 12; m++) {
    const ym = `${y}-${String(m).padStart(2, "0")}`;
    if (ym > ymd(p).slice(0, 7)) break;
    const mf = monthFeed(plant, ym).infos;
    const sum = (label) => r1((mf.find((i) => i.label === label).records).reduce((a, r) => a + Number(r.value), 0));
    if (!mf[0].records.length) continue;
    rec.pv.push({ time: String(m), value: String(sum("PV")) }); rec.load.push({ time: String(m), value: String(sum("Load")) });
    rec.imp.push({ time: String(m), value: String(sum("Purchased")) }); rec.exp.push({ time: String(m), value: String(sum("Sold")) });
    rec.chg.push({ time: String(m), value: String(sum("Charge")) }); rec.dischg.push({ time: String(m), value: String(sum("Discharge")) });
  }
  return { infos: [
    { label: "PV", records: rec.pv }, { label: "Load", records: rec.load },
    { label: "Purchased", records: rec.imp }, { label: "Sold", records: rec.exp },
    { label: "Charge", records: rec.chg }, { label: "Discharge", records: rec.dischg },
  ] };
}
/** Per-inverter history: one series, at the logger's cadence. */
function inverterDay(plantId, inv, day, column) {
  const plant = PLANTS[plantId];
  if (!feedHasDay(plant, day)) return { infos: [] };
  const step = Math.max(1, Math.round(inv.upload / 60));
  const s = inv.share;
  const ctCount = plant.inverters.filter((i) => i.ct).length || 1;
  const scale = (k) => (rec) => rec.map((r) => ({ ...r, value: String(Math.round(Number(r.value) * (k === "grid" ? (inv.ct ? 1 / ctCount : 0) : s))) }));
  const rec = (k) => feedRecords(plant, day, k, step, "full");
  if (column === "soc") return { infos: [{ label: "SOC", unit: "%", records: plant.battKwh > 0 ? rec("soc") : [] }] };
  if (column === "pac" ) return { infos: [{ label: "P-Grid", unit: "W", records: scale("grid")(rec("grid")) }] };
  if (column === "pac-load") return { infos: [{ label: "P-Load", unit: "W", records: scale("load")(rec("load")) }] };
  if (column === "vpv" || column === "ipv") {
    const pvRec = scale("pv")(rec("pv"));
    const infos = [];
    for (let k = 1; k <= 2; k++) {
      infos.push({ label: `${column === "vpv" ? "V" : "I"}-PV-${k}`, records: pvRec.map((r) => {
        const ppv = Number(r.value) / 2; const vpv = ppv > 5 ? 320 + k * 10 : 1.2;
        return { time: r.time, value: column === "vpv" ? String(r1(vpv)) : String(r2(ppv > 5 ? ppv / vpv : 0)) };
      }) });
    }
    return { infos };
  }
  return { infos: [] };
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
const seen = [];
function ok(res, data, extra = {}) {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ code: 0, msg: "Success", success: true, data, ...extra }));
}
function fail(res, status, msg) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ code: status, msg, success: false, data: null }));
}
function page(list, q, pageSize) {
  const limit = Math.min(Number(q.get("limit")) || 20, pageSize || 1000);
  const pg = Math.max(1, Number(q.get("page")) || 1);
  return { pageSize: limit, pageNumber: pg, total: list.length, infos: list.slice((pg - 1) * limit, pg * limit) };
}
function findInverter(sn) {
  for (const [id, plant] of Object.entries(PLANTS)) {
    const inv = plant.inverters.find((i) => i.sn === sn);
    if (inv) return { plantId: Number(id), plant, inv };
  }
  return null;
}
function readBody(req) {
  return new Promise((resolve) => { let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => resolve(b)); });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const path = url.pathname;
  const q = url.searchParams;
  seen.push({ t: Date.now(), path });
  if (seen.length > 5000) seen.splice(0, 1000);

  if (path === "/oauth/token" && req.method === "POST") {
    const body = JSON.parse((await readBody(req)) || "{}");
    const user = body.grant_type === "refresh_token" ? String(body.refresh_token || "").replace(/^rt:/, "") : String(body.username || "");
    if (!ACCOUNTS[user] || (body.grant_type === "password" && !body.password)) return ok(res, null, { msg: "username or password error" });
    return ok(res, { access_token: `at:${user}`, refresh_token: `rt:${user}`, token_type: "bearer", expires_in: 604800, scope: "all" });
  }
  if (path === "/__calls") { res.writeHead(200, { "Content-Type": "application/json" }); return res.end(JSON.stringify(seen.slice(-500))); }

  const bearer = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  const user = bearer.replace(/^at:/, "");
  const acc = ACCOUNTS[user];
  if (!acc) return fail(res, 401, "unauthorized");
  const myPlants = acc.plants.map((id) => ({ id, name: PLANTS[id].name }));

  let m;
  if (path === "/plants") return ok(res, page(myPlants, q, acc.pageSize));
  if ((m = /^\/plant\/(\d+)$/.exec(path))) {
    const plant = PLANTS[m[1]];
    if (!plant || !acc.plants.includes(Number(m[1]))) return fail(res, 404, "no such plant");
    return ok(res, { id: Number(m[1]), name: plant.name, timezone: { code: plant.tz }, currency: { code: plant.currency }, lat: plant.lat, lon: plant.lon, totalPower: plant.kwp });
  }
  if (path === "/inverters") {
    const list = acc.plants.flatMap((id) => PLANTS[id].inverters.map((i) => ({
      sn: i.sn, alias: i.alias, plant: { id, name: PLANTS[id].name }, model: i.model, equipModel: i.model, status: 1, gsn: `E${i.sn}`,
      version: { softVer: "1.6.2", hmiVer: "E.4.3.1" }, commTypeName: "WiFi",
    })));
    return ok(res, page(list, q, acc.pageSize));
  }
  if ((m = /^\/inverter\/([A-Z0-9]+)\/realtime\/(input|output)$/.exec(path))) {
    const f = findInverter(m[1]); if (!f) return fail(res, 404, "no such inverter");
    return ok(res, inverterRealtime(f.plantId, f.inv)[m[2]]);
  }
  if ((m = /^\/inverter\/(grid|battery|load)\/([A-Z0-9]+)\/realtime$/.exec(path))) {
    const f = findInverter(m[2]); if (!f) return fail(res, 404, "no such inverter");
    return ok(res, inverterRealtime(f.plantId, f.inv)[m[1]]);
  }
  if ((m = /^\/plant\/energy\/(\d+)\/(day|month|year)$/.exec(path))) {
    const plant = PLANTS[m[1]]; if (!plant) return fail(res, 404, "no such plant");
    const date = q.get("date") || "";
    if (m[2] === "day") return ok(res, plantDayFeed(plant, date));
    if (m[2] === "month") return ok(res, monthFeed(plant, date));
    return ok(res, yearFeed(plant, date));
  }
  if ((m = /^\/inverter\/battery\/([A-Z0-9]+)\/day$/.exec(path))) { const f = findInverter(m[1]); return f ? ok(res, inverterDay(f.plantId, f.inv, q.get("date"), "soc")) : fail(res, 404, "x"); }
  if ((m = /^\/inverter\/grid\/([A-Z0-9]+)\/day$/.exec(path))) { const f = findInverter(m[1]); return f ? ok(res, inverterDay(f.plantId, f.inv, q.get("date"), "pac")) : fail(res, 404, "x"); }
  if ((m = /^\/inverter\/load\/([A-Z0-9]+)\/day$/.exec(path))) { const f = findInverter(m[1]); return f ? ok(res, inverterDay(f.plantId, f.inv, q.get("date"), "pac-load")) : fail(res, 404, "x"); }
  if ((m = /^\/inverter\/([A-Z0-9]+)\/input\/day$/.exec(path))) { const f = findInverter(m[1]); return f ? ok(res, inverterDay(f.plantId, f.inv, q.get("date"), q.get("column"))) : fail(res, 404, "x"); }
  return fail(res, 404, `mock: no route for ${path}`);
});

server.listen(PORT, () => console.log(`mock sunsynk on :${PORT} — accounts: ${Object.keys(ACCOUNTS).join(", ")}`));
