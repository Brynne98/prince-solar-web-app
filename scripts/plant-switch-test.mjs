// Plant switch (SOLAR-646): an answer asked for before a switch must not land after it.
// Runs the app's modules (scripts/app-modules.mjs) with a Supabase stub
// whose replies come back only when the test lets them.
//   node scripts/plant-switch-test.mjs    exit 1 on any failure
import { browser, loadApp } from './app-modules.mjs';

const pending = [];
browser();
globalThis.sbStub = {
  auth: { onAuthStateChange() { return { data: { subscription: { unsubscribe() {} } } }; } },
  // each reply waits until release() and answers with the plant it was asked for
  rpc: (fn, params) => new Promise((res) => pending.push(() => res({ data: { plant: params.p_plant, days: params.p_plant }, error: null }))),
};
const ctx = await loadApp();
const release = async (i) => { pending[i](); await new Promise(r => setTimeout(r, 0)); };
const settle = (p) => p.then(v => ({ ok: v }), e => ({ stale: ctx.isStale(e), e }));

let failed = 0;
const test = async (name, fn) => {
  pending.length = 0;
  try { await fn(); console.log('ok   ' + name); } catch (e) { failed += 1; console.log('FAIL ' + name + ': ' + e.message); }
};
const eq = (got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error('got ' + JSON.stringify(got) + ', want ' + JSON.stringify(want)); };

await test('A answered after a switch to B is refused', async () => {
  ctx.setCurrentPlant(1);
  const a = settle(ctx.fetchPlantDays());
  ctx.setCurrentPlant(2);
  const b = settle(ctx.fetchPlantDays());
  await release(1); await release(0);
  eq([await a, await b].map(r => r.ok ?? (r.stale ? 'stale' : 'error')), ['stale', 2]);
});

await test('A, B, A: the first A answered last is refused, the second A is kept', async () => {
  ctx.setCurrentPlant(1);
  const a1 = settle(ctx.fetchPlantDays());
  ctx.setCurrentPlant(2);
  ctx.setCurrentPlant(1);
  const a2 = settle(ctx.fetchPlantDays());
  await release(1); await release(0);
  eq([await a1, await a2].map(r => r.ok ?? (r.stale ? 'stale' : 'error')), ['stale', 1]);
});

await test('the same plant set again (a settings reload) keeps answers in flight', async () => {
  ctx.setCurrentPlant(1);
  const a = settle(ctx.fetchPlantDays());
  ctx.setCurrentPlant(1);
  await release(0);
  eq((await a).ok, 1);
});

await test('a shared answer from before A, B, A is not handed to the second A', async () => {
  ctx.setCurrentPlant(1);
  const a1 = settle(ctx.fetchInverterHistory(null, 0));
  ctx.setCurrentPlant(2);
  ctx.setCurrentPlant(1);
  const a2 = settle(ctx.fetchInverterHistory(null, 0));
  eq(pending.length, 2);
  await release(0); await release(1);
  eq([(await a1).stale, (await a2).ok], [true, []]);
});

if (failed) { console.log(failed + ' failed'); process.exit(1); }
