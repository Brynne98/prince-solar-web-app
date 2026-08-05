// ============================================================================
// data.jsx — Mock data shaped like the SunSynk Connect API (see API.md)
// All numbers are simulated but internally consistent (power balance holds).
// Wire real /api/overview + /api/history into the same shapes later.
// ============================================================================

// --- seeded RNG so charts are stable across re-renders -----------------------
function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const BATT_CAPACITY_KWH = 10.0;     // ~200Ah @ ~51V usable
const BATT_MAX_KW = 5.0;            // charge/discharge ceiling
const SOC_FLOOR = 20;               // reserve

// --- one realistic day of 5-minute samples ----------------------------------
// Returns { points:[{t, pv, load, batt, grid, soc}], totals:{...} }
// Sign conventions for the SERIES:  batt + = charging / − = discharging
//                                   grid + = importing  (this system cannot export)
function simulateDay(seed, fillMinutes /* null = full day */) {
  const rnd = mulberry32(seed);
  const pts = [];
  let soc = 34 + rnd() * 8;          // start of day SOC
  let chgKwh = 0, dischgKwh = 0, pvKwh = 0, loadKwh = 0, impKwh = 0;
  const dt = 5 / 60;                 // hours per step
  // weather factor for the day (cloudy days produce less)
  const weather = 0.78 + rnd() * 0.22;

  for (let m = 0; m < 1440; m += 5) {
    const h = m / 60;
    // ---- PV: bell curve centred ~12:40, sunrise ~6:40 sunset ~17:35 ----
    let pv = 0;
    if (h > 6.6 && h < 17.7) {
      const x = (h - 12.2) / 3.0;
      pv = Math.exp(-x * x) * 9200 * weather;          // peak ~9.2kW (2 inverters)
      pv *= 0.86 + 0.14 * Math.sin(m * 0.7);           // passing-cloud flicker
      // a couple of cloud dips
      if (h > 10.4 && h < 11.0) pv *= 0.45;
      if (h > 14.1 && h < 14.4) pv *= 0.6;
      pv = Math.max(0, pv + (rnd() - 0.5) * 240);
    }
    // ---- Load: base + morning & evening peaks + appliance spikes ----
    let load = 380 + 140 * Math.sin(h / 24 * Math.PI * 2 - 1);
    if (h > 5.8 && h < 8.2) load += 1400 * Math.exp(-Math.pow((h - 6.9) / 0.7, 2)); // geyser am
    if (h > 17.3 && h < 21.5) load += 2100 * Math.exp(-Math.pow((h - 18.9) / 1.1, 2)); // dinner/evening
    if (h > 12 && h < 13.2) load += 900 * Math.exp(-Math.pow((h - 12.5) / 0.3, 2));  // lunch
    load += (rnd() - 0.5) * 220;
    load = Math.max(120, load);

    // ---- balance: PV first to load, surplus charges battery (excess curtailed) ----
    let batt = 0, grid = 0;
    const net = pv - load;
    if (net >= 0) {
      // surplus → charge battery up to limit / 100%; anything beyond is curtailed
      const room = (100 - soc) / 100 * BATT_CAPACITY_KWH; // kWh of headroom
      const maxChargeW = Math.min(BATT_MAX_KW * 1000, room / dt * 1000);
      const charge = Math.min(net, Math.max(0, maxChargeW));
      batt = charge;                       // + charging
      grid = -(net - charge);              // surplus beyond charging exported (− = export) for demo
      soc += charge * dt / 1000 / BATT_CAPACITY_KWH * 100;
      chgKwh += charge * dt / 1000;
    } else {
      const deficit = -net;
      const avail = (soc - SOC_FLOOR) / 100 * BATT_CAPACITY_KWH;
      const maxDischW = Math.min(BATT_MAX_KW * 1000, Math.max(0, avail) / dt * 1000);
      const disch = Math.min(deficit, Math.max(0, maxDischW));
      batt = -disch;                       // − discharging
      grid = deficit - disch;              // import remainder (+ = import)
      soc -= disch * dt / 1000 / BATT_CAPACITY_KWH * 100;
      dischgKwh += disch * dt / 1000;
      if (grid > 0) impKwh += grid * dt / 1000;
    }
    soc = Math.max(SOC_FLOOR - 1, Math.min(100, soc));
    pvKwh += pv * dt / 1000;
    loadKwh += load * dt / 1000;

    if (fillMinutes != null && m > fillMinutes) {
      pts.push({ t: m, pv: null, load: null, batt: null, grid: null, soc: null });
    } else {
      pts.push({
        t: m,
        pv: Math.round(pv), load: Math.round(load),
        batt: Math.round(batt), grid: Math.round(grid),
        soc: Math.round(soc * 10) / 10,
      });
    }
  }
  return {
    points: pts,
    totals: {
      pv: +pvKwh.toFixed(1), load: +loadKwh.toFixed(1),
      chg: +chgKwh.toFixed(1), dischg: +dischgKwh.toFixed(1),
      imp: +impKwh.toFixed(1),
    },
  };
}

// --- many days of aggregate energy (for week / month / year bar charts) ------
function simulateDays(n, endDate) {
  const out = [];
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(endDate);
    d.setDate(d.getDate() - i);
    const seed = d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
    const { totals } = simulateDay(seed, null);
    const selfSuff = Math.min(100, Math.round(((totals.load - totals.imp) / totals.load) * 100));
    out.push({
      date: d.toISOString().slice(0, 10),
      day: d.getDate(),
      dow: d.getDay(),
      label: d.toLocaleDateString('en', { weekday: 'short' }),
      monthLabel: d.toLocaleDateString('en', { month: 'short' }),
      pv: totals.pv, load: totals.load,
      imp: totals.imp,
      chg: totals.chg, dischg: totals.dischg,
      selfSuff,
    });
  }
  return out;
}

// --- live snapshot (matches /api/overview aggregate + per inverter) ----------
// Evening scenario: solar off, battery discharging + grid topping up, both inverters online.
function makeSnapshot(jitter = 0) {
  const j = (base, amp) => Math.max(0, Math.round(base + (Math.random() - 0.5) * amp * (jitter ? 1 : 0)));
  const soc = 58;
  const pvA = 0, pvB = 0;
  const loadA = j(560, 120), loadB = j(540, 120);
  const battA = loadA, battB = loadB;            // battery covers the night load
  const gridA = 0, gridB = 0;
  const today = simulateDay(20260529, 23 * 60 + 10);   // full day captured

  return {
    updated: new Date(),
    plant: { id: 'PLT-2049', name: 'Home · SunSynk' },
    weather: { temp: 14, sunrise: '06:42', sunset: '17:38', desc: 'Clear', nowMin: 23 * 60 + 10 },
    aggregate: {
      pvNow: 0, pvToday: 38.4, pvTotal: 2003.0,
      battSoc: soc, battPower: battA + battB, battState: 'discharging',
      battVoltage: 51.0, battCurrent: -21.5, battTemp: 22.0,
      battChgToday: today.totals.chg, battDischgToday: today.totals.dischg,
      battChgTotal: 749.8, battDischgTotal: 731.0,
      gridPower: 0, gridFromToday: 6.8,
      gridFromTotal: 230.6, gridFreq: 49.99, gridPf: 0.99,
      loadNow: loadA + loadB, loadToday: 44.0, loadTotal: 1745.0,
    },
    inverters: [
      {
        sn: '2512082438', alias: 'Inverter A', model: 'SUNSYNK-8K', status: 'online',
        soft: '1.5.4.7', hmi: '1.0.9.3', gsn: '2212...8841', commissioned: 'Dec 2025',
        pvNow: 0, pvToday: 19.4, pvTotal: 727.3, output: loadA,
        battPower: battA, battState: 'discharging', battSoc: soc, battVolt: 51.0,
        battCurrent: -10.6, battTemp: 22.0, battCap: 200, numberOfBatteries: 1, secondBank: false,
        chgToday: 18.2, dischgToday: 12.4,
        grid: 0, gridFromToday: 3.5,
        load: loadA, loadFreq: 49.99,
        strings: [
          { no: 1, v: 1.6, i: 0.0, p: 0, today: 9.8 },
          { no: 2, v: 1.9, i: 0.0, p: 0, today: 9.6 },
        ],
        phases: [{ volt: 230.4, current: loadA / 230.4, power: loadA }],
        ups: { l1: loadA, l2: 0, l3: 0 },
      },
      {
        sn: '2508290475', alias: 'Inverter B', model: 'SUNSYNK-8K', status: 'online',
        soft: '1.5.4.7', hmi: '1.0.9.3', gsn: '2208...3390', commissioned: 'Aug 2025',
        pvNow: 0, pvToday: 19.0, pvTotal: 1276.1, output: loadB,
        battPower: battB, battState: 'discharging', battSoc: soc, battVolt: 51.1,
        battCurrent: -10.7, battTemp: 22.3, battCap: 200, numberOfBatteries: 1, secondBank: false,
        chgToday: 18.0, dischgToday: 12.1,
        grid: 0, gridFromToday: 3.3,
        load: loadB, loadFreq: 50.0,
        strings: [
          { no: 1, v: 1.7, i: 0.0, p: 0, today: 9.7 },
          { no: 2, v: 1.5, i: 0.0, p: 0, today: 9.4 },
        ],
        phases: [{ volt: 230.7, current: loadB / 230.7, power: loadB }],
        ups: { l1: loadB, l2: 0, l3: 0 },
      },
    ],
  };
}

// --- South African tariff presets (editable; see research notes) -------------
// Import rates in Rand per kWh, incl VAT, indicative 2025/26. Verify on YOUR bill.
const TARIFF_PRESETS = {
  'eskom-homepower': { label: 'Eskom Homepower (flat)', import: 3.10, note: 'Flat residential rate for Eskom-direct customers.' },
  'eskom-homeflex':  { label: 'Eskom Homeflex (TOU avg)', import: 3.32, note: 'Time-of-use tariff; blended average import rate.' },
  'capetown':        { label: 'City of Cape Town', import: 3.35, note: 'Typical residential blended rate.' },
  'joburg':          { label: 'Joburg City Power', import: 3.62, note: 'Highest metro rates; fast solar payback.' },
  'tshwane':         { label: 'City of Tshwane', import: 3.05, note: 'Block tariff; most homes fall in block 2.' },
  'ethekwini':       { label: 'eThekwini (Durban)', import: 3.20, note: 'Typical residential blended rate.' },
  'custom':          { label: 'Custom', import: 3.40, note: 'Enter the exact import rate from your latest bill.' },
};

Object.assign(window, {
  simulateDay, simulateDays, makeSnapshot, TARIFF_PRESETS,
  BATT_CAPACITY_KWH, BATT_MAX_KW,
});
