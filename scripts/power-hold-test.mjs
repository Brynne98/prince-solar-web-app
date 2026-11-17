#!/usr/bin/env node
// Hold last good replay (SOLAR-551). Feeds 24 h of recorded SunSynk reads of plant 538820
// (scripts/fixtures/power-flow, one row per minute per inverter, recorded 15-16 Nov) through
// the poller's freshness gate and the same holdLastGood() the poller runs, then counts plant
// minutes where solar + grid + battery misses home by more than 400 W, and how old the
// stored battery/grid/home figures get.
// Recording signs: batt + = discharging, grid + = import. Stored: batt_w + = charging.
// Run by `npm test`; exit 1 on a failure.
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { holdLastGood, ownGap, MAX_HOLD_RUN } from '../supabase/functions/poll/hold.mts';

const SNS = ['2508290475', '2512082438'];
const MAX_CARRIED_RUN = 5; // poll/index.ts
const rows = readFileSync(new URL('fixtures/power-flow/sunsynk-recording-2026-11-16.jsonl', import.meta.url), 'utf8')
  .trim().split('\n').map(JSON.parse);

function replay(hold) {
  let state = {}, n = 0, off = 0, longest = 0, oldest = 0, ts = 0;
  for (const r of rows) {
    ts += 60;
    // same minutes as score-recording.js: both inverters and the app answered cleanly
    if (!(r.app && !r.app.err && SNS.every((s) => r[s] && r[s].time && !(r[s].err || []).length))) { state = {}; continue; }
    let plantGap = 0;
    for (const s of SNS) {
      const x = r[s], st = state[s];
      // canCarry(): same upload time, under the carry cap, and the last row not held
      const carry = st && st.row.device_time === x.time && st.carriedRun < MAX_CARRIED_RUN && !st.row.held;
      // `age`: minutes since batt/grid/load were last read (test-only field)
      const row = carry
        ? { ...st.row, ts, pv_w: x.pac, age: st.row.age + 1 }
        : { ts, device_time: x.time, pv_w: x.pac, batt_w: -x.batt, grid_w: x.grid, load_w: x.load, age: 0 };
      if (hold) {
        holdLastGood(row, st?.row);
        if (row.held) row.age = st.row.age + 1;
      }
      state[s] = { row, carriedRun: carry ? st.carriedRun + 1 : 0 };
      plantGap += ownGap(row);
      longest = Math.max(longest, row.held ?? 0);
      oldest = Math.max(oldest, row.age);
    }
    n++;
    if (Math.abs(plantGap) > 400) off++;
  }
  return { n, off, longest, oldest };
}

const today = replay(false), held = replay(true);
console.log(`power hold: ${today.n} minutes scored; off >400 W today ${today.off}, with hold ${held.off}; ` +
  `longest hold ${held.longest} min; oldest figures ${today.oldest} min today, ${held.oldest} min with hold`);
assert.equal(today.n, 668, 'minutes scored');
assert.equal(today.off, 57, 'baseline matches score-recording.js');
assert.ok(held.off <= 9, `with hold: ${held.off} minutes off, want <= 9`);
assert.ok(held.longest <= MAX_HOLD_RUN, `longest hold ${held.longest} min, want <= ${MAX_HOLD_RUN}`);
// a hold is followed by a full read, never by carries of the held figures
assert.ok(held.oldest <= MAX_HOLD_RUN + MAX_CARRIED_RUN - 1, `figures ${held.oldest} min old`);

// unit cases
const good = { ts: 0, pv_w: 1000, batt_w: 200, grid_w: 0, load_w: 800 };
const bad = { ts: 60, pv_w: 1000, batt_w: 2000, grid_w: 0, load_w: 800, batt_soc: 61 };
let r = { ...bad }; holdLastGood(r, good);
assert.deepEqual([r.batt_w, r.held, r.batt_soc], [200, 1, 61], 'holds the four, keeps the rest');
r = { ...bad }; holdLastGood(r, { ...good, held: MAX_HOLD_RUN });
assert.deepEqual([r.batt_w, r.held], [2000, null], 'stores the read after the cap');
r = { ...bad }; holdLastGood(r, { ...bad, ts: 0 });
assert.equal(r.held, null, 'no hold when the previous row was off too');
r = { ...bad, batt_w: null }; holdLastGood(r, good);
assert.equal(r.held, null, 'no hold on a missing figure');
r = { ...bad, ts: 3600 }; holdLastGood(r, good);
assert.equal(r.held, null, 'no hold from a row older than the minute before');
r = { ...bad, batt_w: 600 }; holdLastGood(r, { ...good, batt_w: 590, load_w: 790 });
assert.equal(r.held, null, 'no hold on a steady loss near 400 W (no jump)');
// a real step (538820 slave, geysers at 04:02 on 17 Nov): held one minute at most
const before = { ts: 0, pv_w: 0, batt_w: -360, grid_w: 0, load_w: 300 };
const step = (ts) => ({ ts, pv_w: 0, batt_w: -5328, grid_w: 0, load_w: 4771 });
const m1 = step(60); holdLastGood(m1, before);
const m2 = step(120); holdLastGood(m2, m1);
assert.deepEqual([m1.held, m2.held, m2.load_w], [1, null, 4771], 'real step shows by the second minute');
console.log('power hold: ok');
