#!/usr/bin/env node
// At most N SunSynk requests in flight per login (SOLAR-649): supabase/functions/_shared/limit.mts.
// Run by `npm test`; exit 1 on a failure.
import assert from 'node:assert/strict';
import { slot } from '../supabase/functions/_shared/limit.mts';

const tick = () => new Promise((r) => setTimeout(r, 5));
let now = 0, peak = 0, other = 0;
const job = async (key, max) => {
  const done = await slot(key, max);
  if (key === 'a') { now++; peak = Math.max(peak, now); } else other++;
  await tick();
  if (key === 'a') now--;
  done();
};
// 50 requests on login a, 3 on login b: a never passes 10 at once, b is not held up by a
const b = Promise.all([1, 2, 3].map(() => job('b', 10)));
await Promise.all([...Array(50)].map(() => job('a', 10)));
await b;
assert.equal(peak, 10, 'login a peaked at ' + peak);
assert.equal(other, 3);
assert.equal(now, 0);
// all places free again: the next 10 start at once
const t0 = Date.now();
await Promise.all([...Array(10)].map(() => job('a', 10)));
assert.ok(Date.now() - t0 < 40, 'a freed login runs at once');
// a task that throws still frees its place (sunsynk.ts calls done() in finally)
const fail = async () => { const done = await slot('c', 1); try { throw new Error('x'); } finally { done(); } };
await assert.rejects(fail());
await Promise.race([job('c', 1), new Promise((_, no) => setTimeout(() => no(new Error('c stuck')), 200))]);
// a waiter that runs out of time gives up and takes nothing; the place still works after
const hold = await slot('d', 1);
await assert.rejects(slot('d', 1, 30), /waited 30 ms/);
hold();
const again = await Promise.race([slot('d', 1, 100), new Promise((_, no) => setTimeout(() => no(new Error('d stuck')), 200))]);
again();
// the cap changes under load (poll lanes): a smaller one retires places, a larger one lets waiters in
{
  let inF = 0, top = 0;
  const run = async (max, ms) => { const done = await slot('e', max); inF++; top = Math.max(top, inF); await new Promise((r) => setTimeout(r, ms)); inF--; done(); };
  const first = [...Array(20)].map(() => run(10, 20));
  await tick();
  const later = [...Array(20)].map(() => run(4, 20));   // cap down to 4 while 10 run and 10 wait
  await Promise.all(first);
  top = 0;
  await Promise.all(later);
  assert.ok(top <= 4, 'after the cap fell to 4, peak was ' + top);
  const held = await slot('f', 1);
  const waiting = [slot('f', 1), slot('f', 1)];
  const grown = await Promise.race([slot('f', 4), new Promise((_, no) => setTimeout(() => no(new Error('f stuck')), 200))]);
  const both = await Promise.race([Promise.all(waiting), new Promise((_, no) => setTimeout(() => no(new Error('waiters left behind')), 200))]);
  [held, grown, ...both].forEach((d) => d());
}
console.log('limit-test: ok');
