#!/usr/bin/env node
/**
 * Physics integrity audit — CLI for DATA_PIPELINE.md §9A/§9B.
 *
 *   §9A  every day's energy balance must close (in ≈ out, residual ≲ 150 W)
 *   §9B  batt_w > 0 (charging) must coincide with SOC rising
 *
 * Usage:  node scripts/integrity-check.js [days]     (default 60)
 * Exit:   0 = every day balances · 1 = at least one day flagged
 *
 * The server runs the same report nightly (startIntegrityWatch) and serves it
 * at /api/integrity — this CLI is for cron/launchd or a manual spot-check.
 */
require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const db = require('../db');

const days = Math.max(1, Math.min(400, Number(process.argv[2]) || 60));
const rep = db.integrityReport(days);

if (!rep.days.length) {
  console.log('No logged days in the window — nothing to audit.');
  process.exit(0);
}

const pad = (v, n) => String(v ?? '—').padStart(n);
const kwh = (v) => (v == null ? '—' : v.toFixed(1));
console.log(`\nIntegrity audit — last ${days} day(s), ${rep.days.length} with data (poller rows only; grid x-check = integral vs 2×master counter)`);
console.log('date        minutes  gap  rec  avg-resid  sign  grid int/ctr  batt°C(avg/max)  hrs-full  flags');
for (const d of rep.days) {
  const temp = `${d.avgTempC ?? '—'}/${d.maxTempC ?? '—'}`;
  console.log(
    `${d.date}  ${pad(d.minutes, 7)}  ${pad(d.gapMin, 3)}  ${pad(d.recoveredMin, 3)}  ${pad(d.avgResidualW + 'W', 9)}  ${pad(`${d.signViolations}/${d.signChecked}`, 6)}  ${pad(`${kwh(d.gridIntegralKwh)}/${kwh(d.gridCounterKwh)}`, 12)}  ${pad(temp, 15)}  ${pad(d.hrsAtFull, 8)}  ${d.flags.length ? d.flags.join(',') : 'ok'}`
  );
}

const gaps = db.recentGaps(10);
if (gaps.length) {
  const fmt = (ts) => new Date(ts * 1000).toLocaleString('en-ZA', { dateStyle: 'short', timeStyle: 'short' });
  console.log('\nRecent logger-offline windows:');
  for (const g of gaps) console.log(`  ${fmt(g.from_ts)} → ${fmt(g.to_ts)}  (${g.minutes} min)`);
}

if (rep.flagged.length) {
  console.error(`\nFLAGGED: ${rep.flagged.join(', ')} — see DATA_PIPELINE.md §9 for diagnosis.`);
  process.exit(1);
}
console.log('\nAll days balance. ✓');
