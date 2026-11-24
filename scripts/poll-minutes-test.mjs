#!/usr/bin/env node
// Each login's refresh minutes (SOLAR-650): stable, spread over all ten and all sixty
// minutes, apart within one shard, and the hourly minute never on a list minute.
// Run by `npm test`; exit 1 on a failure.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { isListMinute, isPlantsMinute, listMinute, plantsMinute } from '../supabase/functions/poll/minutes.mts';

// Fixed uuid-shaped ids (a hash of the index), so the spread checks give the same answer every run.
const ids = Array.from({ length: 6000 }, (_, i) => {
  const h = createHash('sha256').update(String(i)).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
});
const shardOf = (id, shards) => parseInt(id.slice(0, 8), 16) % shards; // 0246

// stable
for (const id of ids.slice(0, 50)) {
  assert.equal(listMinute(id), listMinute(id));
  assert.equal(plantsMinute(id), plantsMinute(id));
}

// in range, never both on one minute
for (const id of ids) {
  const l = listMinute(id), p = plantsMinute(id);
  assert.ok(l >= 0 && l < 10 && p >= 0 && p < 60);
  assert.notEqual(p % 10, l);
}

// spread: each bucket within 30% of even, for the fleet and within one shard of two
const spread = (list, f, n) => {
  const c = new Array(n).fill(0);
  for (const id of list) c[f(id)]++;
  const even = list.length / n;
  for (const k of c) assert.ok(Math.abs(k - even) < even * 0.3, `bucket ${k} vs ${even}`);
};
spread(ids, listMinute, 10);
spread(ids, plantsMinute, 60);
spread(ids.filter((id) => shardOf(id, 2) === 0), listMinute, 10);
spread(ids.filter((id) => shardOf(id, 5) === 0), listMinute, 10);

// the checks the poller makes, over one hour of minutes
const id = ids[0];
const hour = 1764000000 - (1764000000 % 3600);
const mins = Array.from({ length: 60 }, (_, i) => hour + i * 60);
assert.equal(mins.filter((ts) => isListMinute(id, ts)).length, 6);
assert.equal(mins.filter((ts) => isPlantsMinute(id, ts)).length, 1);
assert.equal(mins.filter((ts) => isListMinute(id, ts) && isPlantsMinute(id, ts)).length, 0);

console.log('poll-minutes-test: ok');
