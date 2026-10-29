// Warning tests (SOLAR-231): does each warning the app shows fire on a real problem and stay
// quiet on real normal data? Runs the built app code (public/build/, `npm run build` first)
// against api_overview answers recorded from production, changed one fact at a time.
//   node scripts/warning-tests.mjs        exit 1 on any failure
// A case marked `gap` is a known wrong answer, kept so the fix can be proven: its body
// returns whether the answer is right; false prints GAP and does not fail the run, true
// prints FIXED (drop its mark then). A gap case that throws is a failure like any other.
import { readFileSync } from 'node:fs';
import { createContext, runInContext } from 'node:vm';

const root = new URL('..', import.meta.url);
const fixture = name => JSON.parse(readFileSync(new URL('scripts/fixtures/warnings/' + name + '.json', root), 'utf8'));

// The page's globals, enough for the data and check code to load. auth.js and link.js need a real
// Supabase client and hold no warning, so they are left out.
const stub = () => new Proxy(function () {}, { get: (t, k) => (k === Symbol.toPrimitive ? () => '' : stub()), apply: () => stub(), construct: () => stub() });
const ctx = { console, setTimeout, clearTimeout, setInterval, clearInterval, URL, URLSearchParams, Intl };
Object.assign(ctx, { window: ctx, React: stub(), ReactDOM: stub(), document: stub(), localStorage: stub(), sessionStorage: stub(),
  navigator: stub(), supabase: stub(), posthog: stub(), fetch: () => new Promise(() => {}), addEventListener() {}, removeEventListener() {},
  location: { search: '', hostname: 'localhost', href: 'http://localhost/' }, matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
createContext(ctx);
for (const f of ['config.js', 'build/data.js', 'build/components.js', 'build/app.js', 'build/flow.js', 'build/chart.js', 'build/tabs.js'])
  runInContext(readFileSync(new URL('public/' + f, root), 'utf8'), ctx, { filename: f });

// One recorded answer, changed by `edit`, through the page's own snapshot code.
async function snap(name, edit = () => {}) {
  const api = fixture(name);
  edit(api, Object.fromEntries(api.inverters.map(i => [i.sn, i])));
  ctx.getJSON = async () => api;
  return ctx.fetchSnapshot();
}
const at = s => new Date(s.updated).getTime(); // judge as of the recorded answer
const issues = st => st.issues.map(i => i.title);
const ago = (api, s) => Math.floor(Date.parse(api.generatedAt) / 1000) - s; // readAt s seconds old

const cases = [];
const test = (name, fn, opts = {}) => cases.push({ name, fn, ...opts });
const eq = (got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error('got ' + JSON.stringify(got) + ', want ' + JSON.stringify(want)); };

// ---- Inverter online or offline ---------------------------------------------------------
test('slave with SunSynk status 0, reading 94 s old, is online (SOLAR-226)', async () => {
  const s = await snap('overview-three-shared-offgrid');
  eq(s.inverters.find(i => i.sn === 'S1').status, 'online');
});
test('slave reading 10 min old (worst seen in 7 days) is online', async () => {
  const s = await snap('overview-two-shared-grid', (a, i) => { i.S1.readAt = ago(a, 600); });
  eq(s.inverters.find(i => i.sn === 'S1').status, 'online');
});
test('reading 16 min old with SunSynk status 1 is offline', async () => {
  const s = await snap('overview-two-shared-grid', (a, i) => { i.S1.readAt = ago(a, 960); });
  eq(s.inverters.find(i => i.sn === 'S1').status, 'offline');
});
test('no reading time: SunSynk status 0 is offline, 1 is online', async () => {
  const s = await snap('overview-two-shared-grid', (a, i) => { i.S1.readAt = null; i.S1.status = 0; i.M1.readAt = null; });
  eq(s.inverters.map(i => [i.sn, i.status]), [['S1', 'offline'], ['M1', 'online']]);
});

// ---- Header: Live, Stale, Offline -------------------------------------------------------
test('normal minute reads Live', async () => {
  const s = await snap('overview-three-shared-offgrid');
  eq(ctx.plantStatus(s, at(s)).status, 'live');
});
test('one inverter 16 min quiet reads Stale, 1 of 3 offline', async () => {
  const s = await snap('overview-three-shared-offgrid', (a, i) => { i.S2.readAt = ago(a, 960); });
  const p = ctx.plantStatus(s, at(s));
  eq([p.status, p.detail], ['stale', '1 of 3 inverters offline']);
});
test('poller 4 min behind reads Stale', async () => {
  const s = await snap('overview-two-shared-grid', a => { a.lastTs -= 240; });
  eq(ctx.plantStatus(s, at(s)).status, 'stale');
});
test('poller 16 min behind reads Offline', async () => {
  const s = await snap('overview-two-shared-grid', a => { a.lastTs -= 960; });
  eq(ctx.plantStatus(s, at(s)).status, 'offline');
});
test('poller on time, every inverter 16 min quiet, reads Offline', async () => {
  const s = await snap('overview-two-shared-grid', (a, i) => { i.S1.readAt = ago(a, 1000); i.M1.readAt = ago(a, 980); });
  const p = ctx.plantStatus(s, at(s));
  eq([p.status, p.detail], ['offline', '2 of 2 inverters offline']);
});

// ---- Equipment --------------------------------------------------------------------------
test('three inverters, shared battery, normal minute: nothing needs a look', async () => {
  const s = await snap('overview-three-shared-offgrid');
  const st = ctx.equipmentState(s, null, at(s));
  eq([issues(st), st.battTemp], [[], 29]);
});
test('two inverters, shared battery, normal minute: nothing needs a look', async () => {
  const s = await snap('overview-two-shared-grid');
  eq(issues(ctx.equipmentState(s, null, at(s))), []);
});
test('shared battery, no inverter reads a temperature: sensor not reading', async () => {
  const s = await snap('overview-three-shared-offgrid', (a, i) => { i.M1.battery.temperature = -100; });
  eq(ctx.equipmentState(s, null, at(s)).badSensor, true);
});
test('separate batteries, one reads -100: sensor not reading', async () => {
  const s = await snap('overview-two-shared-grid', a => { a.config.batteryBanks = 'per-inverter'; });
  eq(ctx.equipmentState(s, null, at(s)).badSensor, true);
});
test('battery 46 °C is hot, 45 °C is not', async () => {
  const hot = async t => { const s = await snap('overview-two-shared-grid', (a, i) => { i.M1.battery.temperature = t; }); return ctx.equipmentState(s, null, at(s)).hot; };
  eq([await hot(46), await hot(45)], [true, false]);
});
test('inverter 16 min quiet: header and Equipment both name it', async () => {
  const s = await snap('overview-three-shared-offgrid', (a, i) => { i.S2.readAt = ago(a, 960); });
  eq([ctx.plantStatus(s, at(s)).detail, issues(ctx.equipmentState(s, null, at(s)))], ['1 of 3 inverters offline', ['Inverter S2 isn’t reporting']]);
});
// Recorded 2026-10-29 05:17 on 538820: a battery answer came back empty (0 V, 0 %, 0 °C)
// between normal minutes at 76 % and 25.8 °C. The poller now stores its live fields as
// unknown (SOLAR-231), so the master's battery reads null for that minute.
test('empty battery answer: no sensor warning, no 0 °C, plant charge from the slave', async () => {
  const s = await snap('overview-two-shared-grid', (a, i) => { Object.assign(i.M1.battery, { soc: null, temperature: null, voltage: null, current: null, power: null, signedPower: null }); });
  const st = ctx.equipmentState(s, null, at(s));
  eq([issues(st), st.battTemp, s.aggregate.battSoc], [[], null, 99]);
});

test('empty battery answer on a plant with one battery inverter shows no charge, not 0 %', async () => {
  const s = await snap('overview-two-shared-grid', (a, i) => {
    a.inverters = [i.M1]; a.totals.soc = null;
    Object.assign(i.M1.battery, { soc: null, temperature: null, voltage: null, current: null, power: null, signedPower: null });
  });
  eq([s.aggregate.battSoc, issues(ctx.equipmentState(s, null, at(s)))], [null, []]);
});

// ---- Panels -----------------------------------------------------------------------------
const health = (todayKwh2, edit = () => {}) => {
  const h = { todayKwh: 14.37, historyDays: 14, inverters: [
    { sn: 'M1', strings: [{ no: 2, todayKwh: todayKwh2, todayInvShare: 1, usualInvShare: 1, todayPlantShare: todayKwh2 / 14.37, usualPlantShare: 0.5254 }], battFull: false },
    { sn: 'S1', strings: [{ no: 2, todayKwh: 6.54, todayInvShare: 1, usualInvShare: 1, todayPlantShare: 0.4554, usualPlantShare: 0.4746 }], battFull: false }] };
  edit(h);
  return h;
};
test('panels: 3 days of history is still learning, no alert', async () => {
  const s = await snap('overview-two-shared-grid');
  eq(ctx.panelsVerdict(health(7.83, h => { h.historyDays = 3; }), s, at(s)).state, 'learning');
});
test('panels: normal day, no alert', async () => {
  const s = await snap('overview-two-shared-grid');
  eq(ctx.panelsVerdict(health(7.83), s, at(s)).state, 'normal');
});
test('panels: a string that made nothing while its sibling made 6.5 kWh alerts', async () => {
  const s = await snap('overview-two-shared-grid');
  const v = ctx.panelsVerdict(health(0.01), s, at(s));
  eq([v.state, v.alerts.map(x => x.kind)], ['alert', ['nothing']]);
});
test('panels: that dead string still alerts on a day the battery was full', async () => {
  const s = await snap('overview-two-shared-grid');
  const v = ctx.panelsVerdict(health(0.01, h => h.inverters.forEach(i => { i.battFull = true; })), s, at(s));
  eq([v.state, v.alerts.map(x => x.kind)], ['alert', ['nothing']]);
});
test('panels: on a full-battery day a string at a third of usual is not called low', async () => {
  const s = await snap('overview-two-shared-grid');
  const v = ctx.panelsVerdict(health(2.5, h => h.inverters.forEach(i => { i.battFull = true; })), s, at(s));
  eq([v.state, v.alerts], ['unchecked', []]);
});

let fail = 0, gaps = 0;
for (const c of cases) {
  let err = null, ok;
  try { ok = await c.fn(); } catch (e) { err = e; }
  if (err) { fail++; console.log(`FAIL  ${c.name}: ${err.message}`); }
  else if (c.gap) {
    if (ok === true) console.log(`FIXED ${c.name}: passes now, remove its gap mark`);
    else { gaps++; console.log(`GAP   ${c.name}: ${c.gap}`); }
  }
  else console.log(`PASS  ${c.name}`);
}
console.log(`${cases.length - fail - gaps} passed, ${fail} failed, ${gaps} known gaps`);
process.exit(fail ? 1 : 0);
