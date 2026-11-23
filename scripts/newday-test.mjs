#!/usr/bin/env node
// A new day's first rows (SOLAR-648): the poller's today counters do not cross the plant's
// midnight. Cases from 538820 and 495944 on the night of 23-24 Nov 2026.
// Run by `npm test`; exit 1 on a failure.
import assert from 'node:assert/strict';
import { clearYesterday, dayTurned, fromPrev, localDay, TODAY_COUNTERS } from '../supabase/functions/poll/newday.mts';

const TZ = 'Africa/Johannesburg';
const at = (s) => Math.floor(new Date(s).getTime() / 1000); // '2026-11-24T00:00:00+02:00'
const row = (ts, device_time, counters) => ({ ts, device_time, ...counters });

// the plant's date, not UTC's: 00:00 SAST is still the 23rd in UTC
assert.equal(localDay(TZ, at('2026-11-24T00:00:00+02:00')), '2026-11-24');
assert.equal(localDay(TZ, at('2026-11-23T23:59:00+02:00')), '2026-11-23');

// dayTurned: only when the last row is from an earlier plant day
const midnight = at('2026-11-24T00:00:00+02:00');
assert.equal(dayTurned(TZ, midnight, { ts: at('2026-11-23T23:59:00+02:00') }), true);
assert.equal(dayTurned(TZ, midnight + 60, { ts: midnight }), false);
assert.equal(dayTurned(TZ, midnight, null), false);
assert.equal(dayTurned(TZ, midnight, {}), false);

// fromPrev: a today counter from the last row is 0 across midnight; anything else is kept
assert.equal(fromPrev('load_today_kwh', 13.6, true), 0);
assert.equal(fromPrev('load_today_kwh', 13.6, false), 13.6);
assert.equal(fromPrev('load_total_kwh', 9000, true), 9000);
assert.equal(fromPrev('batt_soc', null, true), null);

// clearYesterday: the slave's carried 00:00 row, uploaded 23:55:47 the day before
{
  const r = row(midnight, '2026-11-23 23:55:47', { pv_today_kwh: 0, load_today_kwh: 13.6, batt_chg_today_kwh: 12.8, grid_import_today_kwh: 0, load_total_kwh: 9000 });
  clearYesterday(r, TZ);
  for (const k of TODAY_COUNTERS) if (k in r) assert.equal(r[k], 0, k);
  assert.equal(r.load_total_kwh, 9000, 'lifetime totals stay');
}
// a fresh read whose battery endpoint still says yesterday (495944, 19.8 kWh charged at 00:00)
{
  const r = row(midnight, '2026-11-23 23:59:40', { batt_chg_today_kwh: 19.8, batt_dischg_today_kwh: null });
  clearYesterday(r, TZ);
  assert.equal(r.batt_chg_today_kwh, 0);
  assert.equal(r.batt_dischg_today_kwh, null, 'unknown stays unknown');
}
// today's upload: kept as read
{
  const r = row(midnight + 120, '2026-11-24 00:00:52', { load_today_kwh: 0.1 });
  clearYesterday(r, TZ);
  assert.equal(r.load_today_kwh, 0.1);
}
// a late-evening row, still yesterday: kept
{
  const r = row(at('2026-11-23T23:59:00+02:00'), '2026-11-23 23:58:47', { load_today_kwh: 17 });
  clearYesterday(r, TZ);
  assert.equal(r.load_today_kwh, 17);
}
// a malformed or missing upload time: left alone, nothing to date it by
for (const dt of [null, '', 'garbage', '2026-11-23']) {
  const r = row(midnight, dt, { load_today_kwh: 5 });
  clearYesterday(r, TZ);
  assert.equal(r.load_today_kwh, 5, String(dt));
}
// a logger clock ahead of the plant: never zeroed by this rule
{
  const r = row(at('2026-11-23T23:59:00+02:00'), '2026-11-24 08:59:00', { load_today_kwh: 8.4 });
  clearYesterday(r, TZ);
  assert.equal(r.load_today_kwh, 8.4);
}

console.log('newday-test: ok');
