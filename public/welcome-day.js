// ---------- the example day ----------
// Shapes only; not anyone's real plant. Worked out in 5-minute steps from a 10 kWh pack,
// so the charge, the kWh totals and the boxes in the flow all agree. South African
// installs don't export: spare solar goes to the battery, and once it is full the
// inverter holds the panels back to what the house uses.
window.DEMO = (() => {
  const CAP = 10, RESERVE = 20, MAX_CHARGE = 4, KWP = 7; // kWh, %, kW, kW of panels
  // A seeded random, so the example day is the same on every visit.
  let seed = 20260318;
  const rnd = () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
  const STEPS = Array.from({ length: 288 }, (_, k) => k / 12);
  // Solar: a clear morning, then cumulus from 12:30 that cuts it back in bursts, as on a
  // Highveld summer afternoon; a little flicker on every reading.
  let cloud = 0;
  const SOLAR = STEPS.map(h => {
    if (h < 5.75 || h > 18.75) return 0;
    const clear = Math.pow(Math.max(0, Math.sin(Math.PI * (h - 5.75) / 13)), 1.25) * 5.8;
    if (cloud > 0) cloud--; else if (h > 12.5 && h < 17 && rnd() < 0.22) cloud = 1 + Math.floor(rnd() * 3);
    const shade = cloud > 0 ? 0.3 + rnd() * 0.35 : 1;
    return Math.max(0, clear * shade * (0.97 + rnd() * 0.06));
  });
  // Home: fridge cycling, kettle and toaster at breakfast, pool pump 09:00 to 16:00, the
  // geyser element switching on and off 10:30 to 14:30 and again 16:30 to 18:00, cooking and
  // lights in the evening.
  const HOME = STEPS.map((h, k) => {
    let w = 0.38 + (Math.floor(k / 4) % 3 === 0 ? 0.14 : 0) + rnd() * 0.08;
    if (h >= 6 && h < 8.5) w += 0.35 + rnd() * 0.3;
    if ([79, 82, 88, 202, 233].includes(k)) w += 2.1;          // kettle
    if (k === 80) w += 1.0;                                     // toaster
    if (h >= 9 && h < 16) w += 1.15;                            // pool pump
    if (h >= 10.5 && h < 14.5 && Math.floor((h - 10.5) * 3) % 3 !== 2) w += 3.0; // geyser element
    if (h >= 16.5 && h < 18 && Math.floor((h - 16.5) * 4) % 3 !== 2) w += 3.0; // geyser again
    if (h >= 17 && h < 19.25) w += 1.1 + rnd() * 0.9;           // cooking
    if (h >= 18 && h < 22.5) w += 0.35;                          // lights, TV
    return w;
  });
  const solarAt = (h) => SOLAR[Math.min(287, Math.floor(h * 12))];
  const homeAt = (h) => HOME[Math.min(287, Math.floor(h * 12))];
  const gridOff = (h) => h >= 18 && h < 20.5;
  // one row per 5 minutes, in kW: solar, battery (+ = powering the house, - = charging),
  // grid bought, home; charge % at the start of the step
  const day = (soc0) => {
    const rows = [];
    let soc = soc0;
    for (let k = 0; k < 288; k++) {
      const h = k / 12, home = homeAt(h), off = gridOff(h), spare = solarAt(h) - home;
      // A real inverter never holds the grid at exactly 0: it draws a trickle, 20 to 90 W,
      // and a big load switching on (kettle, geyser) pulls from the grid for a moment
      // before the inverter catches up.
      const jump = k > 0 ? home - homeAt((k - 1) / 12) : 0;
      const trickle = off ? 0 : 0.02 + rnd() * 0.07 + (jump > 1.5 && rnd() < 0.7 ? jump * (0.25 + rnd() * 0.3) : 0);
      let batt = 0, grid = 0, pv = solarAt(h);
      if (spare >= 0) {
        grid = trickle;
        batt = -Math.min(spare + grid, MAX_CHARGE, (100 - soc) / 100 * CAP * 12);
        pv = home - batt - grid;
      } else {
        if (soc > RESERVE || off) batt = Math.min(-spare, Math.max(0, soc) / 100 * CAP * 12);
        if (!off) { grid = Math.max(-spare - batt, trickle); batt = -spare - grid; }
      }
      rows.push({ pv, batt, grid, home, soc, off });
      soc -= batt / 12 / CAP * 100;
    }
    return { rows, end: soc };
  };
  // run the day twice so midnight starts where the day before ended
  const { rows } = day(day(50).end);
  const at = (h) => rows[Math.min(287, Math.floor(h * 12))];

  // The last 30 days for the bars: the example day's totals, scaled by the weather.
  const ymd = (d) => d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  const today = ymd(new Date());
  const fullPv = rows.reduce((s, r) => s + r.pv / 12, 0);
  const days = Array.from({ length: 30 }, (_, i) => {
    const d = new Date(); d.setDate(d.getDate() - 29 + i);
    const sun = 0.62 + 0.38 * Math.abs(Math.sin(i * 1.93 + 0.7)) - (i % 9 === 4 ? 0.35 : 0);
    return { date: ymd(d), pv: +(fullPv * sun).toFixed(1), imp: +(3.2 + (1 - sun) * 9.5).toFixed(1) };
  });

  return { CAP, RESERVE, KWP, rows, at, days, today };
})();
