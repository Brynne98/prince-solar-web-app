// Billing screen tests (SOLAR-641): the pick, plans and confirm rules the SQL state test cannot
// reach, run on the built app code (public/build/, `npm run build` first) with made-up account
// states in api_account_state's shape.
//   node scripts/billing-screen-test.mjs        exit 1 on any failure
import { readFileSync } from 'node:fs';
import { createContext, runInContext } from 'node:vm';

const root = new URL('..', import.meta.url);
const stub = () => new Proxy(function () {}, { get: (t, k) => (k === Symbol.toPrimitive ? () => '' : stub()), apply: () => stub(), construct: () => stub() });
const ctx = { console, setTimeout, clearTimeout, setInterval, clearInterval, URL, URLSearchParams, Intl };
Object.assign(ctx, { window: ctx, React: stub(), ReactDOM: stub(), document: stub(), localStorage: stub(), sessionStorage: stub(),
  navigator: stub(), supabase: stub(), sb: stub(), posthog: stub(), fetch: () => new Promise(() => {}), addEventListener() {}, removeEventListener() {},
  location: { search: '', hostname: 'localhost', href: 'http://localhost/' }, matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
createContext(ctx);
for (const f of ['config.js', 'build/text.js', 'build/link.js', 'build/data.js', 'build/components.js', 'build/app.js', 'build/flow.js', 'build/chart.js', 'build/tabs.js'])
  runInContext(readFileSync(new URL('public/' + f, root), 'utf8'), ctx, { filename: f });

const plant = (id, o = {}) => ({ plant: id, name: 'Plant ' + id, chosen: false, purged: false, logins: ['L1'], claimed: false, kept_elsewhere: false, ...o });
const prices = [
  { plan: 'home', name: 'Home', places: 2, interval: 'month', amount_minor: 4900, currency: 'ZAR' },
  { plan: 'home', name: 'Home', places: 2, interval: 'year', amount_minor: 49000, currency: 'ZAR' },
  { plan: 'family', name: 'Family', places: 5, interval: 'month', amount_minor: 9900, currency: 'ZAR' },
  { plan: 'family', name: 'Family', places: 5, interval: 'year', amount_minor: 99000, currency: 'ZAR' },
];
const acct = (o = {}) => ({ state: 'active', plan: 'home', interval: 'month', places: 2, open: 1, may_choose: true, prices,
  logins: [{ id: 'L1', username: 'me@example.com' }], plants: [], ...o });
const ids = (groups) => groups.flatMap(g => g.plants.map(p => p.plant_id));

const cases = [];
const test = (name, fn) => cases.push({ name, fn });
const eq = (got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error('got ' + JSON.stringify(got) + ', want ' + JSON.stringify(want)); };

// ---- 1: a plant whose history was deleted stays choosable -------------------------------
test('pickers list a purged plant that is not chosen (fix 1)', () => {
  const a = acct({ plants: [plant(1, { chosen: true }), plant(2, { purged: true })] });
  eq(ids(ctx.pickLogins(a, 'choose')), [1, 2]);
  eq(ids(ctx.pickLogins(a, 'checkout')), [1, 2]);
  eq(ids(ctx.pickLogins(a, 'keep')), [1]);
});
test('after a payment the pick opens for a purged plant waiting (fix 1)', () => {
  eq(ctx.pickWaiting(acct({ plants: [plant(1, { chosen: true }), plant(2, { purged: true })] })), true);
  eq(ctx.pickWaiting(acct({ plants: [plant(1, { chosen: true })] })), false);
});

// ---- 3: nothing to list: no pick, it goes on with none -----------------------------------
test('ended account with no login: checkout goes on with no pick (fix 3)', () => {
  const a = acct({ state: 'ended', plan: null, interval: null, logins: [], plants: [] });
  eq(ctx.planStep(a, prices[0]), { mode: 'checkout', pick: false });
});
test('a smaller plan with nothing chosen: no keep pick (fix 3)', () => {
  const a = acct({ plan: 'family', places: 5, plants: [plant(1)] });
  eq(ctx.planStep(a, prices[0]), { mode: 'keep', pick: false });
  eq(ctx.planStep(acct({ plan: 'family', places: 5, plants: [plant(1, { chosen: true })] }), prices[0]), { mode: 'keep', pick: true });
});
test('plants to list: the checkout pick opens', () => {
  eq(ctx.planStep(acct({ state: 'ended', plan: null, plants: [plant(1)] }), prices[0]), { mode: 'checkout', pick: true });
});

// ---- 12: every change of plants read now is confirmed ------------------------------------
test('adding a plant opens the confirm (fix 12)', () => {
  eq(ctx.pickNext('choose', [], [2]), 'confirm');
  eq(ctx.pickNext('choose', [1], []), 'confirm');
  eq(ctx.pickNext('choose', [], []), 'close');
});
test('the checkout pick confirms a chosen plant going, not a plant coming (fix 12)', () => {
  eq(ctx.pickNext('checkout', [1], [2]), 'confirm');
  eq(ctx.pickNext('checkout', [], [2]), 'done');
  eq(ctx.pickNext('keep', [1], []), 'done');
});
test('the confirm for a plant coming says it starts', () => {
  const t = ctx.AccountText.switchConfirm(acct({ plants: [plant(1, { chosen: true }), plant(2)] }), [], [2]);
  eq([t.title, t.button], ['Read Plant 2?', 'Read']);
});

// ---- 13: a running plan changes plan at its own interval ---------------------------------
test('running monthly plan, yearly view: other plans stay monthly (fix 13)', () => {
  const rows = ctx.planRows(acct(), 'year');
  eq(rows.map(r => r.plan + ':' + r.interval), ['home:year', 'family:month']);
});
test('no plan running: the view decides every row', () => {
  eq(ctx.planRows(acct({ state: 'ended', plan: null }), 'year').map(r => r.plan + ':' + r.interval), ['home:year', 'family:year']);
});

// ---- 17: removing the shared group names its plants --------------------------------------
test('remove the shared group: its claimed plants go (fix 17)', () => {
  const a = acct({ plants: [plant(7, { name: 'Gran', logins: [], claimed: true, chosen: true }), plant(1, { chosen: true })] });
  eq(ctx.AccountText.removeLogin(a, 'share-login-id', true), ['Gran: history deleted now.']);
  eq(ctx.AccountText.removeLogin(a, 'L1'), ['Plant 1: history deleted now.']);
});

// ---- 9: the refund email names the card the payment came from ----------------------------
test('refund email: the refunded payment\'s card, not the saved one (fix 9)', () => {
  const s = { ...acct(), card: { card_type: 'visa', last4: '9999' }, time_zone: 'Africa/Johannesburg', locale: 'en-ZA', currency: 'ZAR' };
  const m = ctx.AccountText.mail({ key: 'refund', state: s, refund: { amount_minor: 4900, currency: 'ZAR', reference: 'R1', reason: 'stale',
    paid_at: '2026-12-01T08:00:00Z', paid_minor: 4900, card_type: 'mastercard', last4: '1111' } });
  const hero = m.parts.find(p => p.hero).hero;
  eq(hero.sub, 'back to Mastercard •••• 1111');
});

// ---- final review fixes -------------------------------------------------------------------
const tz = { time_zone: 'Africa/Johannesburg', locale: 'en-ZA', currency: 'ZAR' };
test('checkout confirm: nothing changes until the payment goes through (final fix 8)', () => {
  const a = acct({ ...tz, plants: [plant(1, { chosen: true }), plant(2)] });
  eq(ctx.AccountText.switchConfirm(a, [1], [2], true).lines,
    ['When the payment goes through:', 'Plant 1 stops and its history is deleted.', 'Plant 2 starts.', 'Switching often slows history loading.']);
  eq(ctx.AccountText.switchConfirm(a, [1], [], false).lines, ['Plant 1 stops and its history is deleted now.']);
});
test('delete reminder, plants on different dates: never one date for all (final fix 10)', () => {
  const s = { ...acct(), ...tz, access_ended_at: '2026-12-01T08:00:00Z', history_kept_until: '2026-12-31T08:00:00Z',
    plants: [plant(1, { chosen: true, delete_at: '2026-12-31T08:00:00Z' }), plant(2, { chosen: true, delete_at: '2027-01-20T08:00:00Z' })] };
  const m = ctx.AccountText.mail({ key: 'history_delete_soon', state: s });
  eq(m.subject, 'History of Plant 1 is deleted on 31 Dec 2026');
  eq(m.parts[0].lead, 'Readings stopped on 1 Dec 2026. Plant 2: history kept until 20 Jan 2027. A plan before 31 Dec 2026 keeps it all.');
  const one = ctx.AccountText.mail({ key: 'history_delete_soon', state: { ...s, plants: [s.plants[0]] } });
  eq(one.subject, 'Your history is deleted on 31 Dec 2026');
});
test('delete account: each reason its own words, no link to a section not shown (final fix 15)', () => {
  const d = (o) => ctx.AccountText.deleteBlocked({ ...acct(), ...tz, may_delete: false, owed_minor: 0, dispute_open: false, plan_name: 'Home', cancel_at: null, ...o });
  eq(d({ may_delete: true }), null);
  eq([d({ cancel_at: '2027-01-03T08:00:00Z' }).title, d({ cancel_at: '2027-01-03T08:00:00Z' }).to], ['Home ends on 3 Jan 2027', null]);
  eq([d({ dispute_open: true }).title, d({ dispute_open: true }).to], ['A payment is in dispute', null]);
  eq(d({ state: 'past_due' }).to, 'billing');
  eq([d({ state: 'ended', plan_name: null, owed_minor: 4900 }).title, d({ state: 'ended', plan_name: null, owed_minor: 4900 }).to], ['R49 is owed', 'mail']);
  eq(d({}).to, 'cancel');
  eq([d({ plan_name: null }).to, /null/.test(d({ plan_name: null }).text)], ['mail', false]);
});
test('a running plan with no saved card: Add card (final fix 16)', () => {
  eq(ctx.cardAction(acct({ card: null })), 'Add card');
  eq(ctx.cardAction(acct({ card: { last4: '4242' } })), 'Change card');
  eq(ctx.cardAction(acct({ state: 'ended', plan: null, card: null })), null);
});
test('signed in: the account read again on every ps-account (final fix 14)', () => {
  // the app files again, with hooks that run: useEffect at once, setState recorded
  const on = {}, sets = [];
  const R = new Proxy({ useState: (v) => [v, (x) => sets.push(x)], useEffect: (f) => { f(); } }, { get: (t, k) => t[k] ?? stub() });
  const c = { ...ctx, React: R, addEventListener: (k, f) => (on[k] ??= []).push(f), removeEventListener() {} };
  c.window = c;
  createContext(c);
  for (const f of ['config.js', 'build/text.js', 'build/link.js', 'build/data.js', 'build/components.js', 'build/app.js'])
    runInContext(readFileSync(new URL('public/' + f, root), 'utf8'), c, { filename: f });
  c.checkReturn = c.loadPages = () => new Promise(() => {});
  c.SignedIn();
  const ended = { state: 'ended' };
  c.accountNow = () => ended;
  (on['ps-account'] || []).forEach(f => f());
  eq(sets.includes(ended), true);
});

let failed = 0;
for (const c of cases) {
  try { await c.fn(); console.log('ok    ' + c.name); }
  catch (e) { failed++; console.log('FAIL  ' + c.name + ': ' + e.message); }
}
console.log(`${cases.length} billing screen tests, ${failed} failed`);
process.exit(failed ? 1 : 0);
