#!/usr/bin/env node
// SOLAR-681 R22: the page's one retry. Run by `npm test`; exit 1 on a failure.
import assert from 'node:assert/strict';
import { minuteMissing, RETRY_MS } from '../public/live-retry.mjs';

const FRESH = 15 * 60000, m = (h, mi, s = 0) => Date.UTC(2026, 10, 27, h, mi, s);
assert.equal(minuteMissing(m(10, 5), m(10, 5, 20), FRESH), false, 'this minute saved: no retry');
assert.equal(minuteMissing(m(10, 4), m(10, 5, 14), FRESH), true, 'the minute before: retry');
assert.equal(minuteMissing(m(9, 30), m(10, 5, 14), FRESH), false, 'a quiet plant (35 min): no retry, it waits');
assert.equal(minuteMissing(null, m(10, 5, 14), FRESH), false, 'no reading: no retry');
assert.equal(minuteMissing(new Date(m(10, 4)), new Date(m(10, 5, 41)), FRESH), true, 'Dates work as epoch ms');
assert.equal(RETRY_MS, 5000, 'once more 5 s later');
console.log('live retry: 6 checks passed');
