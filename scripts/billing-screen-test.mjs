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
  const a = acct({ plants: [plant(7, { name: 'Gran', logins: [], claimed: true, shared: true, chosen: true }), plant(1, { chosen: true })] });
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
  const s = { ...acct(), ...tz, at: '2026-12-10T08:00:00Z', access_ended_at: '2026-12-01T08:00:00Z', history_kept_until: '2026-12-31T08:00:00Z',
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

// ---- verify review fixes -------------------------------------------------------------------
test('pay with another card while past due: the card page, never the saved card (verify fix 2)', async () => {
  const sent = [];
  const c = { ...ctx, AbortSignal, fetch: async (url, o) => { sent.push(JSON.parse(o.body)); return { ok: true, json: async () => ({ status: 'pending' }) }; } };
  c.window = c;
  createContext(c);
  for (const f of ['config.js', 'build/text.js', 'build/link.js']) runInContext(readFileSync(new URL('public/' + f, root), 'utf8'), c, { filename: f });
  c.sb = { auth: { getSession: async () => ({ data: { session: { access_token: 't' } } }) } };
  c.toast = () => {};
  await c.settlePayment();
  eq(sent, [{ settle: true, newCard: true }]);
});
test('pay screen: each plant with its own date, a date passed left out (verify fix 14)', () => {
  const s = { ...acct(), ...tz, state: 'ended', plan: null, had_plan: true, last_plan_name: 'Home', at: '2026-12-10T08:00:00Z',
    access_ended_at: '2026-12-01T08:00:00Z', history_kept_until: '2026-12-31T08:00:00Z', history_purged: false,
    plants: [plant(1, { chosen: true, delete_at: '2026-12-31T08:00:00Z' }), plant(2, { chosen: true, delete_at: '2027-01-20T08:00:00Z' }),
      plant(3, { chosen: true, delete_at: '2026-12-09T08:00:00Z' })] };
  eq(ctx.AccountText.payScreen(s).body,
    'Readings have stopped. Plant 1: history kept until 31 Dec 2026. Plant 2: history kept until 20 Jan 2027.');
  // the date covers only Plant 1 (Plant 3's has passed): named (verify 4 fix 6)
  eq(ctx.AccountText.payScreen({ ...s, plants: [s.plants[0], s.plants[2]] }).body, 'Readings have stopped. Plant 1: history kept until 31 Dec 2026.');
  const m = ctx.AccountText.mail({ key: 'history_delete_soon', state: { ...s, history_kept_until: '2027-01-20T08:00:00Z', plants: [s.plants[2], s.plants[1]] } });
  eq(m.subject, 'History of Plant 2 is deleted on 20 Jan 2027');
});

test('remove the shared group: a plant whose share was removed is named too (verify 2 fix 4)', () => {
  const a = acct({ plants: [plant(7, { name: 'Gran', logins: [], claimed: false, shared: true, chosen: true }), plant(1, { chosen: true })] });
  eq(ctx.AccountText.removeLogin(a, 'share-login-id', true), ['Gran: history deleted now.']);
});
test('remove the shared group: a plant that did not come through the share is not named (verify 3 fix 9)', () => {
  const a = acct({ plants: [plant(7, { name: 'Gran', logins: [], claimed: true, shared: true, chosen: true }),
    plant(8, { name: 'Other', logins: [], shared: false, chosen: true })] });
  eq(ctx.AccountText.removeLogin(a, 'share-login-id', true), ['Gran: history deleted now.']);
});
test('one delete date for only some plants names them (verify 3 fix 7)', () => {
  const s = { ...acct(), ...tz, state: 'ended', plan: null, had_plan: true, last_plan_name: 'Home', at: '2026-12-10T08:00:00Z',
    access_ended_at: '2026-12-01T08:00:00Z', history_kept_until: '2026-12-31T08:00:00Z', history_purged: false,
    plants: [plant(1, { chosen: true, delete_at: '2026-12-31T08:00:00Z' }), plant(2, { chosen: true, kept_elsewhere: true, delete_at: null })] };
  eq(ctx.AccountText.payScreen(s).body, 'Readings have stopped. Plant 1: history kept until 31 Dec 2026.');
  eq(ctx.AccountText.mail({ key: 'trial_ended', state: s }).parts[0].lead.includes('Plant 1: history kept until 31 Dec 2026.'), true);
  const m = ctx.AccountText.mail({ key: 'history_delete_soon', state: s });
  eq([m.subject, m.parts[0].lead], ['History of Plant 1 is deleted on 31 Dec 2026',
    'Readings stopped on 1 Dec 2026. A plan before 31 Dec 2026 keeps it.']);
});
test('remove: a plant gone from two logins goes with either one (verify 4 fix 3)', () => {
  const a = acct({ logins: [{ id: 'L1', username: 'a' }, { id: 'L2', username: 'b' }],
    plants: [plant(5, { logins: [], gone_logins: ['L1', 'L2'], chosen: true }), plant(6, { logins: ['L2'], gone_logins: ['L1'], chosen: true })] });
  eq(ctx.AccountText.removeLogin(a, 'L1'), ['Plant 5: history deleted now.']);
  eq(ctx.AccountText.removeLogin(a, 'L2'), ['Plant 5 and Plant 6: history deleted now.']);
});
test('remove: a plant gone from its login, then claimed, goes with the share only (verify 4 fix 3)', () => {
  const a = acct({ plants: [plant(6, { name: 'Gran', logins: [], gone_logins: ['L1'], claimed: true, shared: true, chosen: true })] });
  eq(ctx.AccountText.removeLogin(a, 'L1'), ['No chosen plant goes with it.']);
  eq(ctx.AccountText.removeLogin(a, 'share-login-id', true), ['Gran: history deleted now.']);
  eq(ctx.acctLogins(a).map(g => g.kind), ['share']);
});
test('delete refused on a stale screen: the account is read again and its fresh reason shown (verify 4 fix 7)', async () => {
  const fresh = acct({ may_delete: false, plan_name: 'Home' }), was = ctx.reloadAccount;
  ctx.reloadAccount = () => Promise.resolve(fresh);
  eq(await ctx.deleteRefusal('cancel your plan first'), { blocked: true });
  ctx.reloadAccount = () => Promise.resolve(acct({ may_delete: true }));
  eq(await ctx.deleteRefusal('a payment is open'), { text: 'A payment is still going through. Try again tomorrow.', cancel: false });
  ctx.reloadAccount = was;
  eq(readFileSync(new URL('public/build/tabs.js', root), 'utf8').includes('ps-billing'), false);
});
test('one delete date, another chosen plant already deleted: names the plant (verify 4 fix 6)', () => {
  const s = { ...acct(), ...tz, state: 'ended', plan: null, had_plan: true, last_plan_name: 'Home', at: '2026-12-10T08:00:00Z',
    access_ended_at: '2026-12-01T08:00:00Z', history_kept_until: '2026-12-31T08:00:00Z', history_purged: false,
    plants: [plant(1, { chosen: true, delete_at: '2026-12-31T08:00:00Z' }), plant(2, { chosen: true, purged: true, delete_at: null })] };
  eq(ctx.AccountText.payScreen(s).body, 'Readings have stopped. Plant 1: history kept until 31 Dec 2026.');
});
test('a delete date already passed shows no "kept until" (verify 2 fix 10)', () => {
  const s = { ...acct(), ...tz, at: '2026-12-10T08:00:00Z' };
  eq(ctx.AccountText.plantKept(s, plant(1, { chosen: true, delete_at: '2026-12-09T08:00:00Z' })), null);
  eq(ctx.AccountText.plantKept(s, plant(1, { chosen: true, delete_at: '2026-12-31T08:00:00Z' })), 'History kept until 31 Dec 2026');
});
test('a plan from us ended: pay screen and Billing say so, not the free week (verify 2 fix 13)', () => {
  const s = { ...acct(), ...tz, state: 'ended', plan: null, plan_name: null, had_plan: false, grant_ended: true,
    access_ended_at: '2026-12-01T08:00:00Z', plants: [] };
  eq(ctx.AccountText.payScreen(s).title, 'Your plan from us has ended');
  eq(ctx.AccountText.planStatus(s), 'Plan from us ended on 1 Dec 2026');
});
test('a change on a cancelled plan is refused with Keep first (verify 2 fix 5)', () => {
  eq(ctx.AccountText.refused('the plan is cancelled'), 'Keep your plan first.');
});

test('remove login with a payment pending: history kept while it is pending (verify 5 fix 6)', () => {
  const a = acct({ plants: [plant(1, { chosen: true, payment_hold: true }), plant(2, { chosen: true })] });
  eq(ctx.AccountText.removeLogin(a, 'L1'), ['Plant 2: history deleted now.', 'Plant 1: history kept while a payment is pending.']);
});
test('delete refused while a read is on its way: waits for it, then reads again (verify 5 fix 7)', async () => {
  const stale = acct({ may_delete: true }), fresh = acct({ may_delete: false, plan_name: 'Home' });
  const was = [ctx.reloadAccount, ctx.accountLoading];
  let landed = false;
  const pending = new Promise((r) => setTimeout(() => { landed = true; r(stale); }, 5));
  ctx.accountLoading = () => (landed ? null : pending);
  ctx.reloadAccount = () => (landed ? Promise.resolve(fresh) : pending);
  eq(await ctx.deleteRefusal('cancel your plan first'), { blocked: true });
  [ctx.reloadAccount, ctx.accountLoading] = was;
});
test('an interval switch booked with a plan change names the next plan (verify 5 fix 8)', () => {
  const s = { ...acct(), ...tz, plan_name: 'Family', next_plan_name: 'Home', next_interval: 'year', period_end: '2026-12-31T08:00:00Z',
    next_amount_minor: 49000 };
  eq(ctx.AccountText.mail({ key: 'change_booked', state: s, event: { kind: 'interval', before: null, after: null } }).subject,
    'Home is paid yearly from 31 Dec 2026');
});

// ---- SOLAR-644: an unpaid renewal says what happened and what to do ----------------------
const T = () => ctx.AccountText;
const unpaid = (o = {}) => ({ ...acct(), time_zone: 'Africa/Johannesburg', locale: 'en-ZA', currency: 'ZAR', state: 'past_due', plan: 'family',
  plan_name: 'Family', amount_due_minor: 9900, plan_ends_at: '2026-12-08T21:59:59.999Z', at: '2026-11-24T08:00:00Z',
  due_bill: { id: '11111111-2222-3333-4444-555555555555', plan: 'family', plan_name: 'Family', interval: 'month', amount_minor: 9900, currency: 'ZAR' }, ...o });
test('Billing note: each reason its own words, the plan named once (SOLAR-644 §2, council)', () => {
  const end = 'Pay by 8 Dec 2026 or Family ends and readings stop.';
  eq(T().pastDueNote(unpaid({ past_due_reason: 'refused' })).text, `Your R99 payment didn't go through. We removed your saved card. ${end}`);
  eq(T().pastDueNote(unpaid({ past_due_reason: 'no_card' })).text, `Your R99 payment is due. ${end}`);
  eq(T().pastDueNote(unpaid({ past_due_reason: 'retrying', next_try_on: '2026-11-27' })).text,
    `Your R99 payment didn't go through. We'll try your card again on 27 Nov 2026. ${end}`);
  eq(T().pastDueNote(unpaid({ past_due_reason: 'last_try_failed' })).text, `Your R99 payment didn't go through. We won't try your card again. ${end}`);
  eq(T().pastDueNote(unpaid({ past_due_reason: 'checking' })), { text: "We're still checking your R99 payment. You don't need to do anything.", button: null });
  eq(T().pastDueNote(unpaid()).text, `Your R99 payment is overdue. ${end}`);
  eq(T().pastDueNote(unpaid()).button, 'Pay with another card');
});
test('a booked downgrade: the smaller plan is paid, the running plan ends (SOLAR-644 §1e)', () => {
  const s = unpaid({ past_due_reason: 'no_card', due_bill: { id: 'x', plan: 'home', plan_name: 'Home', interval: 'month', amount_minor: 4900, currency: 'ZAR' } });
  eq(T().pastDueNote(s).text, 'Your R49 payment for Home is due. Pay by 8 Dec 2026 or Family ends and readings stop.');
  eq(T().notices(s)[0].title, 'Home payment due');
  eq(T().notices(s)[0].body, 'Pay R49 by 8 Dec 2026 or Family ends and readings stop.');
  eq(T().pastDueNote({ ...s, past_due_reason: 'checking' }).text, "We're still checking your R49 payment for Home. You don't need to do anything.");
});
test('delete account while the bank answers: nothing to pay, try again after (council)', () => {
  eq(T().deleteBlocked(unpaid({ past_due_reason: 'checking' })), { title: "We're checking a payment", text: 'Try again once the check is done.', action: null, to: null });
  eq(T().deleteBlocked(unpaid({ past_due_reason: 'refused' })).title, 'Pay the overdue payment first');
});
test('Live card and bell: built from state, none while the bank answers (SOLAR-644 §5)', () => {
  const n = T().notices(unpaid({ past_due_reason: 'refused', interval: 'year', amount_due_minor: 199000,
    due_bill: { id: 'x', plan: 'family', plan_name: 'Family', interval: 'year', amount_minor: 199000, currency: 'ZAR' } }))[0];
  eq([n.title, n.body, n.button], ['Family payment failed', `Pay ${T().money(199000, 'ZAR')} by 8 Dec 2026 or readings stop.`, 'Pay with another card']);
  eq(T().notices(unpaid({ past_due_reason: 'checking' })).length, 0);
  eq(T().notices(unpaid())[0].title, 'Family payment overdue');
});
test('account menu: payment, login, both; nothing while the bank answers (SOLAR-644 §5)', () => {
  eq(T().accountAlert(unpaid({ past_due_reason: 'refused' }), false), 'Payment failed');
  eq(T().accountAlert(unpaid({ past_due_reason: 'no_card' }), false), 'Payment due');
  eq(T().accountAlert(unpaid({ past_due_reason: 'retrying' }), true), 'Needs attention');
  eq(T().accountAlert(unpaid({ past_due_reason: 'checking' }), true), 'Reconnect a login');
  eq(T().accountAlert(unpaid({ past_due_reason: 'checking' }), false), null);
  eq(T().accountAlert(unpaid(), false), 'Payment due');
});
test('ended while a renewal payment is checked: paused, no plans (SOLAR-644 §2)', () => {
  const s = unpaid({ state: 'ended', plan: null, plan_name: null, last_plan_name: 'Family', had_plan: true, renewal_in_flight: true });
  eq(T().payScreen(s), { title: 'Family', body: "Readings are paused while we check your R99 payment. You don't need to do anything.", button: null });
  eq(T().planTitle(s), 'Family');
  eq(T().planStatus(s), "Readings are paused while we check your R99 payment. You don't need to do anything.");
});
test('emails: soft, refused, no card; the pay-by line under the title; the button names the bill (SOLAR-644 §1, council)', () => {
  const bill = { kind: 'renewal', plan: 'family', plan_name: 'Family', interval: 'month', amount_minor: 9900, currency: 'ZAR', card_type: 'visa', last4: '4081' };
  const sub = "If the payment hasn't gone through by then, Family ends and readings stop.";
  const soft = T().mail({ key: 'payment_failed', state: unpaid({ past_due_reason: 'retrying', next_try_on: '2026-11-27' }), bill });
  eq([soft.subject, soft.title, soft.sub, soft.parts[0].lead], ["Your Family payment didn't go through", 'Pay R99 by 8 Dec 2026', sub,
    "We couldn't charge your Visa •••• 4081. We'll try again on 27 Nov 2026."]);
  eq(soft.parts[1].button, { label: 'Pay with another card', page: 'pay', bill: '11111111-2222-3333-4444-555555555555' });
  eq(soft.parts[2].note, 'Or open Billing in the app.');
  eq(T().mail({ key: 'payment_failed', state: unpaid({ past_due_reason: 'last_try_failed' }), bill: { ...bill, last4: null } }).parts[0].lead,
    "We couldn't charge your saved card. We won't try again.");
  const hard = T().mail({ key: 'card_update', state: unpaid({ past_due_reason: 'refused' }), bill });
  eq([hard.sub, hard.parts[0].lead], [sub, "We couldn't charge your Visa •••• 4081, so we removed it from your account."]);
  const none = T().mail({ key: 'payment_due', state: unpaid({ past_due_reason: 'no_card' }), bill });
  eq([none.subject, none.title, none.sub, none.parts[0].lead], ['Your Family payment is due', 'Pay R99 by 8 Dec 2026', sub, "There's no card saved, so nothing was charged."]);
  const down = T().mail({ key: 'payment_due', state: unpaid(), bill: { ...bill, plan_name: 'Home', amount_minor: 4900 } });
  eq([down.title, down.sub], ['Pay R49 for Home by 8 Dec 2026', sub]);
});
test('plan ended: unpaid says so, unless a payment is still unanswered (SOLAR-644 §1d)', () => {
  const s = unpaid({ state: 'ended', plan_name: null, last_plan_name: 'Family', history_kept_until: null, plants: [] });
  const m = (ended) => T().mail({ key: 'plan_ended', state: s, ended });
  eq([m({ ended_at: '2026-12-08T21:59:59.999Z', reason: 'unpaid', paid_unknown: false }).title,
    m({ ended_at: '2026-12-08T21:59:59.999Z', reason: 'unpaid', paid_unknown: false }).parts[0].lead],
    ['Family ended on 8 Dec 2026', "We didn't receive the renewal payment, so readings have stopped."]);
  eq(m({ ended_at: '2026-12-08T21:59:59.999Z', reason: 'unpaid', paid_unknown: true }).parts[0].lead, 'Readings have stopped.');
  eq(m({ ended_at: '2026-12-08T21:59:59.999Z', reason: 'cancelled', paid_unknown: false }).parts[0].lead, 'Readings have stopped.');
});
test('pay flow words: refusals, paid, closed (SOLAR-644 §6)', () => {
  eq(T().refused('a payment is already in progress'), 'A payment is already in progress.');
  eq(T().refused('this payment has already been made'), 'This payment has already been made.');
  eq(T().refused('this payment is no longer due'), 'This payment is no longer due.');
  eq(T().refused('pay the failed payment first'), 'Pay the overdue payment first.');
  eq(T().paidText({ kind: 'renewal', plan_name: 'Family', changed: false }), 'Payment received. Family carries on.');
  eq(T().paidText({ kind: 'renewal', plan_name: 'Home', changed: true }), 'Payment received. Home is now your plan.');
  eq(T().paidText({ kind: 'purchase', plan_name: 'Home' }), 'Payment received.');
  eq(T().pay.void, 'Payment not completed.');
});

let failed = 0;
for (const c of cases) {
  try { await c.fn(); console.log('ok    ' + c.name); }
  catch (e) { failed++; console.log('FAIL  ' + c.name + ': ' + e.message); }
}
console.log(`${cases.length} billing screen tests, ${failed} failed`);
process.exit(failed ? 1 : 0);
