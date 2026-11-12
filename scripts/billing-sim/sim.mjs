#!/usr/bin/env node
// Billing simulator (SOLAR-264). Local database only. Each household (1-2 users) runs in a transaction
// that is rolled back. Time travel: private.billing_today() is redefined inside that transaction.
//   node scripts/billing-sim/sim.mjs [--seed N] [--households N] [--years N] [--only H] [--trace] [--regress]
// The fixed cases in regress.mjs run first (--regress: only those). Seeds use their own user and plant ids,
// so several seeds can run at once.
// Exit code 0 = every invariant held, 1 = a finding, 2 = the simulator itself broke.
import { Db, SESSION_SQL } from './db.mjs';
import { regress } from './regress.mjs';
import { Oracle, price, step, dom, addDays, dayNo, cyclePos, cover, PLAN_RANK } from './oracle.mjs';

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf('--' + k); return i < 0 ? d : (args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : true); };
const SEED = +opt('seed', 1), NH = +opt('households', 1450), ONLY = opt('only', null), TRACE = !!opt('trace', false);
const YEARS = +opt('years', 3), REGRESS_ONLY = !!opt('regress', false);
const SLOT = SEED % 20; // per-seed id space

// ---- random, seeded per household so one can be replayed alone -------------------------------
function mulberry32(a) { return () => { a |= 0; a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
const mkRng = (seed, h) => { const r = mulberry32((seed * 1000003 + h * 7919 + 12345) >>> 0); const f = () => r(); f.int = (a, b) => a + Math.floor(f() * (b - a + 1)); f.pick = (xs) => xs[Math.floor(f() * xs.length)]; f.chance = (p) => f() < p;
  f.weighted = (m) => { const tot = Object.values(m).reduce((s, x) => s + x, 0); let x = f() * tot; for (const [k, w] of Object.entries(m)) { if ((x -= w) < 0) return k; } return Object.keys(m)[0]; }; return f; };

// ---- findings and coverage ----------------------------------------------------------------------
const findings = new Map(); // signature -> {count, first}
const cov = { events: {}, refused: {}, allowed: {}, charges: {}, paths: {}, days: {}, cycle: new Array(10).fill(0), plantsPerUser: {}, extraInv: {}, users: 0, households: 0, steps: 0, billingDays: {}, periods: {}, endPlans: {}, pastDue: 0, toFree: 0, sharedPlants: 0, pendingLate: 0, run: {}, unbooked: 0 };
const inc = (o, k, n = 1) => { o[k] = (o[k] || 0) + n; };
let simErrors = 0;

function fail(ctx, sig, detail) {
  const f = findings.get(sig) || { count: 0, first: null };
  f.count++;
  if (!f.first) f.first = { ...ctx, detail };
  findings.set(sig, f);
  if (TRACE) console.log('  FINDING', sig, JSON.stringify(detail));
}

const db = new Db();
const uuidOf = (h, i) => `00000000-0000-4000-8${SLOT.toString(16).padStart(3, '0')}-${(h * 10 + i).toString(16).padStart(12, '0')}`;
const PLANT0 = 70000000 + SLOT * 1000000; // + h * 200 + n
const sq = (s) => (s === null || s === undefined ? 'null' : `'${s}'`);
const card = (n) => JSON.stringify({ authorization_code: `AUTH_${n}`, reusable: true, last4: String(1000 + (n % 9000)), card_type: 'visa ', exp_month: '12', exp_year: '2031' });

// ---- one household -------------------------------------------------------------------------------
async function household(h) {
  const rng = mkRng(SEED, h);
  const startDay = rng.pick(['2027-01-', '2027-02-', '2027-03-', '2027-05-', '2027-08-', '2027-11-', '2028-01-', '2028-02-']);
  const t0 = startDay + String(rng.int(1, 28)).padStart(2, '0');
  const nUsers = rng.chance(0.38) ? 2 : 1;
  const H = { h, rng, today: t0, cur: addDays(t0, -1), users: [], inv: new Map(), seq: 0, plantNo: 0, ev: 0, step: 0, ref: 0 };
  const endDate = addDays(t0, 40 + 365 * YEARS);
  H.end = endDate;

  // ---- users and the logins they will link ----
  for (let i = 0; i < nUsers; i++) {
    const U = { i, id: uuidOf(h, i), email: `sim-${SEED}-${h * 10 + i}@sim.test`, o: new Oracle(), logins: [], dead: false, profile: rng.chance(0.18) ? 'bad' : 'good', path: ['free'], accts: new Map(), log: [] };
    U.name = `h${h}u${i}`;
    H.users.push(U);
  }
  // now and then a plant whose inverters never got stored (counts as 1)
  const newPlant = (inv) => { const id = PLANT0 + h * 200 + H.plantNo++; H.inv.set(id, inv ?? (rng.chance(0.04) ? 0 : rng.int(1, 3))); return id; };
  H.newPlant = newPlant;
  const A = H.users[0];
  const nPlantsA = rng.weighted({ 0: 4, 1: 14, 2: 14, 3: 16, 4: 14, 5: 12, 6: 10, 7: 8, 8: 8 });
  const nLoginsA = nPlantsA === 0 ? 1 : Math.min(rng.weighted({ 1: 5, 2: 4, 3: 3, 4: 2 }), Math.max(1, nPlantsA));
  const spread = (n, k) => { const out = new Array(k).fill(0); for (let j = 0; j < n; j++) out[j < k ? j : rng.int(0, k - 1)]++; return out; };
  spread(nPlantsA, nLoginsA).forEach((c, k) => A.logins.push({ name: `sim-${SEED}-${h}-a${k}@login.test`, plants: Array.from({ length: c }, () => newPlant()) }));
  if (nUsers === 2) {
    const B = H.users[1];
    const shared = A.logins.flatMap((l) => l.plants);
    const own = rng.int(0, 3);
    const first = { name: `sim-${SEED}-${h}-b0@login.test`, plants: [] };
    if (shared.length) { first.plants.push(rng.pick(shared)); cov.sharedPlants++; }
    for (let j = 0; j < own; j++) first.plants.push(newPlant());
    if (!first.plants.length) first.plants.push(newPlant());
    B.logins.push(first);
    if (rng.chance(0.3)) B.logins.push({ name: `sim-${SEED}-${h}-b1@login.test`, plants: [newPlant()] });
  }
  // a comped account now and then (accounts from before billing)
  if (rng.chance(0.04)) A.comped = true;

  // ---- events ----
  const evs = [];
  const push = (u, date, type, p = {}) => evs.push({ u, date, type, p, n: evs.length });
  for (const U of H.users) {
    // billing day wanted: 1, 15, 28, 29, 30, 31 mostly
    const wantDay = rng.pick([1, 15, 28, 29, 30, 31, 1, 15, 7, 31, 30, 29]);
    let T = addDays(t0, rng.int(0, 12));
    for (let k = 0; k < 70 && dom(T) !== wantDay; k++) T = addDays(T, 1);
    U.logins.forEach((l, k) => push(U, k === 0 ? addDays(t0, rng.int(0, 2)) : addDays(t0, rng.int(0, 330)), 'link', { login: l }));
    if (U.logins.length === 1 && U.logins[0].plants.length === 0) { /* no plants at all */ }
    if (U.comped || rng.chance(0.9)) push(U, T, 'firstpay', {});
    const span = 365 * YEARS;
    const n = rng.int(12, 30) * YEARS;
    for (let k = 0; k < n; k++) {
      const type = rng.weighted({ upgrade: 13, book: 14, remove: 6, keep: 4, pick: 8, change: 8, card: 3, settle: 5, late: 4, probe: 6, extras: 6, linkmore: 4 });
      push(U, addDays(T, rng.int(-8, span)), type, {});
    }
    // daily switchers: a stretch of days with a pick, plant change, booking or new plant every day or two
    if (rng.chance(0.15)) {
      let d = addDays(T, rng.int(0, span - 90));
      const until = addDays(d, rng.int(30, 90));
      while (d < until) {
        push(U, d, rng.weighted({ change: 5, pick: 6, book: 3, keep: 1, extras: 2, upgrade: 1, linkmore: 1 }), {});
        d = addDays(d, rng.int(1, 2));
      }
    }
    if (U.comped) { U.o.plan = 'family'; U.o.comped = true; }
  }
  evs.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : a.n - b.n));
  H.evs = evs;

  // ---- transaction ----
  await db.exec(`begin;
set local lock_timeout = '30s';
create or replace function private.billing_today() returns date language sql stable as $$ select current_setting('sim.today')::date $$;
-- the oracle prices at list: offers closed (0145)
update private.offers set joins_until = date '2000-01-01';
create or replace function public.plant_bootstrap_kick(p_plant bigint) returns void language plpgsql as $$ begin return; end $$;
create or replace function private.plant_start_fill(p_plant bigint) returns void language plpgsql as $$ begin return; end $$;
-- the owner's pick (0197): each plant is ticked as it links, while the plan has places
create function pg_temp.tick() returns trigger language plpgsql as $$
begin
  if not new.paused then perform private.plant_pick_add(new.user_id, new.plant_id, new.plant_name); end if;
  return new;
end $$;
create trigger a_sim_tick before insert on public.plant_users for each row execute function pg_temp.tick();
select set_config('sim.today', '${t0}', true);`);
  try {
    for (const U of H.users) {
      await db.exec(`insert into auth.users (id, email) values ('${U.id}', '${U.email}');`);
      if (U.comped) await db.exec(`insert into private.billing (user_id, plan, comped) values ('${U.id}', 'family', true);`);
    }
    for (const ev of H.evs) {
      const U = ev.u;
      await advanceTo(H, ev.date);
      await setToday(H, ev.date);
      if (U.dead) continue;
      H.ev++;
      try { await runEvent(H, U, ev); }
      catch (e) { simErrors++; console.error(`SIM ERROR h${h} ${U.name} ${ev.type} ${ev.date}: ${e.stack}`); throw e; }
    }
    await advanceTo(H, H.end);
    for (const U of H.users) {
      await finalChecks(H, U);
      cov.users++;
      inc(cov.paths, U.path.join('>'));
      inc(cov.endPlans, U.o.comped ? 'comped' : U.o.plan + (U.o.state === 'past_due' ? '(past_due)' : ''));
      inc(cov.plantsPerUser, U.o.plants.length);
      if (U.o.day) inc(cov.billingDays, U.o.day);
    }
  } finally {
    await db.exec('rollback;');
  }
  cov.households++;
}

async function setToday(H, d) {
  H.today = d;
  await db.exec(`select set_config('sim.today', '${d}', true);`);
}

// ---- time: run the daily job on every date something is due ---------------------------------------
async function advanceTo(H, target) {
  for (;;) {
    let d = null;
    for (const U of H.users) for (const x of U.o.dueDates()) if (x > H.cur && x <= target && (d === null || x < d)) d = x;
    if (d === null) break;
    await setToday(H, d);
    await runDay(H, d);
    H.cur = d;
  }
  if (target > H.cur) H.cur = target;
}

const ctxOf = (H, U, what) => ({ seed: SEED, household: H.h, user: U ? U.name : null, step: H.step, event: what, date: H.today });

async function runDay(H, d) {
  H.step++;
  // what the oracle expects, per user
  const exp = new Map();
  for (const U of H.users) {
    if (U.dead) continue;
    const before = U.o.charges.length;
    const out = U.o.runDay(d);
    exp.set(U, { out, newCharges: U.o.charges.slice(before) });
  }
  let r = await db.t(`select public.billing_run('${d}'::date)`);
  // another session changing a billing row mid-run can abort the run (the call rolls back whole); try again
  for (let k = 0; k < 4 && !r.ok; k++) { await new Promise((res) => setTimeout(res, 300)); r = await db.t(`select public.billing_run('${d}'::date)`); }
  if (!r.ok) { for (const U of H.users) fail(ctxOf(H, U, 'billing_run'), 'billing_run raised', r.err); await resync(H); return; }
  await db.exec('select pg_temp.fix();');
  for (const U of H.users) {
    if (U.dead) continue;
    const e = exp.get(U);
    const rows = await db.json(`select coalesce(jsonb_agg(to_jsonb(c) order by created_at, reference), '[]') from private.billing_charges c where user_id = '${U.id}' and created_on = '${d}' and kind = 'renewal' and status in ('pending','failed')`);
    const ctx = ctxOf(H, U, 'billing_run');
    const want = e.out.map((o) => ({ amount: o.amount, dueOn: o.dueOn, status: o.status })).sort((a, b) => a.amount - b.amount);
    const got = rows.map((c) => ({ amount: c.amount, dueOn: c.due_on, status: c.status })).sort((a, b) => a.amount - b.amount);
    if (JSON.stringify(want) !== JSON.stringify(got)) fail(ctx, 'run: renewal/retry charges differ from the rules', { want, got });
    rows.forEach((c, i) => {
      const m = e.out[i];
      if (m) { m.ref = c.reference; m.dbAmount = c.amount; }
      if (c.amount < 0) fail(ctx, 'charge negative', c);
    });
    // report what happened to each pending charge
    for (const o of e.out) {
      if (o.status !== 'pending' || !o.ref) continue;
      await reportRenewal(H, U, o, d);
    }
    await check(H, U, 'billing_run');
  }
}

function payOutcome(H, U, allowAbandon = true) {
  const bad = U.profile === 'bad';
  const x = H.rng();
  if (x < (bad ? 0.12 : 0.76)) return 'paid';
  if (x < (bad ? 0.92 : 0.90)) return 'declined';
  if (!allowAbandon) return 'declined';
  return x < (bad ? 0.96 : 0.95) ? 'abandon' : 'twice';
}

async function reportRenewal(H, U, o, d) {
  const outcome = payOutcome(H, U);
  const c = U.o.charges.find((x) => x.ref === o.ref) || o;
  c.ref = o.ref;
  inc(cov.charges, 'renewal');
  if (outcome === 'paid' || outcome === 'twice') {
    const withCents = H.rng.chance(0.5);
    const r = await db.t(`select public.billing_charge_paid('${o.ref}', null, false, ${withCents ? o.dbAmount * 100 : 'null'})`);
    if (!r.ok) { fail(ctxOf(H, U, 'renewal paid'), 'billing_charge_paid raised on a renewal', r.err); return; }
    c.status = 'paid'; U.o.state = 'active'; U.o.pds = null; U.o.paidTotal += o.amount;
    inc(cov.days, 'renewal paid');
    if (outcome === 'twice') {
      const r2 = await db.t(`select public.billing_charge_paid('${o.ref}', null, false, null)`);
      if (!r2.ok || !r2.v.again) fail(ctxOf(H, U, 'renewal paid twice'), 'second payment report is not a no-op', r2);
    }
  } else if (outcome === 'declined') {
    const r = await db.t(`select public.billing_charge_failed('${o.ref}', 'declined')`);
    if (!r.ok) { fail(ctxOf(H, U, 'renewal failed'), 'billing_charge_failed raised', r.err); return; }
    c.status = 'failed'; U.o.renewalFailed(c.dueOn);
    inc(cov.days, 'renewal declined');
  } else { // abandon: left pending; the next run hands it out again (0128)
    cov.pendingLate++;
    inc(cov.days, 'renewal pending');
  }
}

// ---- snapshot and comparison ------------------------------------------------------------------------
async function snap(U) { return db.json(`select pg_temp.snap('${U.id}')`); }

async function check(H, U, what, pre) {
  const s = await snap(U);
  const o = U.o, ctx = ctxOf(H, U, what);
  const b = s.b;
  const lab = o.comped ? 'comped' : o.plan + (o.period ? o.period[0].toUpperCase() : '');
  if (U.path[U.path.length - 1] !== lab) U.path.push(lab);
  const bad = [];
  const eq = (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) bad.push([name, got, want]); };
  if (!b) { eq('no billing row: plan', 'free', o.plan); }
  else {
    eq('plan', b.plan, o.plan); eq('period', b.period, o.period); eq('billing_day', b.billing_day, o.day);
    eq('next_billing_date', b.next_billing_date, o.next); eq('state', b.state, o.state); eq('past_due_since', b.past_due_since, o.pds);
    eq('next_plan', b.next_plan, o.nextPlan); eq('next_period', b.next_period, o.nextPeriod);
    eq('plants_to_remove', [...b.plants_to_remove].sort((x, y) => x - y), [...o.rm].sort((x, y) => x - y));
    eq('remove_on', b.remove_on, o.rmOn); eq('comped', b.comped, o.comped);
    eq('extra_plants', b.extra_plants, o.extra); eq('next_extra_plants', b.next_extra_plants, o.nextExtra);
    eq('prepaid_on', b.prepaid_on, o.prepaid);
  }
  const dbPaused = new Map(s.plants.map((p) => [p.id, p.paused]));
  eq('plants linked', [...dbPaused.keys()].sort((x, y) => x - y), o.plants.map((p) => p.id).sort((x, y) => x - y));
  const pausedWant = o.plants.map((p) => [p.id, p.paused]).sort((x, y) => x[0] - y[0]);
  const pausedGot = [...dbPaused.entries()].sort((x, y) => x[0] - y[0]);
  if (JSON.stringify(pausedWant) !== JSON.stringify(pausedGot)) bad.push(['plants collecting (paused flags)', pausedGot, pausedWant]);
  eq('ticks (plant, holds a place)', s.ticks, [...o.ticks].sort((x, y) => x[0] - y[0]));
  eq('last plant change', s.changed, o.changedOn);
  const st = o.status(), g = s.st;
  eq('screen: plan', g.plan, st.plan); eq('screen: period', g.period, st.period); eq('screen: state', g.state, st.state);
  eq('screen: nextAmount', g.nextAmount, st.nextAmount); eq('screen: price', g.price, st.price); eq('screen: nextDate', g.nextDate, st.nextDate);
  eq('screen: nextPlan', g.nextPlan, st.nextPlan); eq('screen: nextPeriod', g.nextPeriod, st.nextPeriod);
  eq('screen: removePlants', g.removePlants.map((x) => x.id).sort((x, y) => x - y), st.removePlants);
  eq('screen: removeOn', g.removeOn, st.removeOn);
  eq('screen: extraPlants', g.extraPlants, st.extraPlants); eq('screen: nextExtraPlants', g.nextExtraPlants, st.nextExtraPlants); eq('billing_amount_due', s.due, st.nextAmount);
  // independent of the oracle: no plant collects beyond what the plan covers
  const act = s.plants.filter((p) => !p.paused).length;
  // rooms from the oracle (0156: Free 1, Home 2, Family 5 + extras held)
  const room = cover(b ? b.plan : 'free', b ? b.extra_plants : 0);
  if (!(b && b.comped) && act > room) bad.push([`plant collects free: ${b ? b.plan : 'free'} past its room`, act, room]);
  if (s.due < 0 || (g.price !== null && g.price < 0)) bad.push(['negative figure', s.due, '>=0']);
  if (b && b.plan !== 'free' && !b.comped) {
    // next date never moves except by the clamp rule: it is the billing day clamped into its month
    const nd = b.next_billing_date, dd = b.billing_day;
    if (nd && dom(nd) !== Math.min(dd, new Date(Date.UTC(+nd.slice(0, 4), +nd.slice(5, 7), 0)).getUTCDate())) bad.push(['next date not on billing day', nd, dd]);
  }
  for (const [name, got, want] of bad) fail(ctx, `${what}: ${name}`, { got, want });
  if (bad.length) { await resyncUser(U, s); return false; }
  return true;
}

async function resyncUser(U, s) {
  const o = U.o, b = s.b;
  if (b) { o.plan = b.plan; o.period = b.period; o.day = b.billing_day; o.next = b.next_billing_date; o.state = b.state; o.pds = b.past_due_since; o.nextPlan = b.next_plan; o.nextPeriod = b.next_period; o.rm = new Set(b.plants_to_remove); o.rmOn = b.remove_on; o.extra = b.extra_plants; o.nextExtra = b.next_extra_plants; o.prepaid = b.prepaid_on; o.nextKeep = b.next_keep; }
  else { o.plan = 'free'; o.period = o.day = o.next = o.pds = o.nextPlan = o.nextPeriod = o.rmOn = o.nextExtra = o.prepaid = null; o.extra = 0; o.rm = new Set(); o.nextKeep = []; }
  o.ticks = new Map(s.ticks); o.changedOn = s.changed;
  const paused = new Map(s.plants.map((p) => [p.id, p.paused]));
  o.plants = o.plants.filter((p) => paused.has(p.id));
  for (const p of o.plants) p.paused = paused.get(p.id);
}
async function resync(H) { for (const U of H.users) await resyncUser(U, await snap(U)); }

// refusals must leave state unchanged
async function sameState(H, U, what, before) {
  const after = await snap(U);
  if (JSON.stringify(before) !== JSON.stringify(after)) fail(ctxOf(H, U, what), `${what}: refused but state changed`, { before: before.b, after: after.b });
}

// ---- events -------------------------------------------------------------------------------------------
async function runEvent(H, U, ev) {
  H.step++;
  const o = U.o, rng = H.rng;
  inc(cov.events, ev.type);
  if (TRACE) console.log(`[h${H.h} ${U.name}] ${ev.date} ${ev.type} plan=${o.plan}/${o.period} plants=${o.plants.map((p) => (p.paused ? '-' : '+') + p.inv).join('')}${o.nextPlan || o.nextPeriod || o.nextExtra !== null ? ` booked=${o.nextPlan}/${o.nextPeriod}/${o.nextExtra} keep=[${o.nextKeep}]` : ''}${o.rm.size ? ` rm=[${[...o.rm]}] on ${o.rmOn}` : ''}`);
  switch (ev.type) {
    case 'link': return doLink(H, U, ev.p.login);
    case 'linkmore': {
      if (H.plantNo > 190) return;
      const login = { name: `sim-${SEED}-${H.h}-${U.i}x${H.ev}@login.test`, plants: Array.from({ length: rng.int(1, 3) }, () => H.newPlant()) };
      return doLink(H, U, login);
    }
    case 'firstpay': return doUpgrade(H, U, { first: true });
    case 'upgrade': return doUpgrade(H, U, {});
    case 'extras': return doUpgrade(H, U, { extras: true });
    case 'book': return doBook(H, U);
    case 'remove': return doRemove(H, U);
    case 'keep': return doKeep(H, U);
    case 'pick': return doPick(H, U);
    case 'change': return doChange(H, U);
    case 'card': return doCard(H, U);
    case 'settle': return doSettle(H, U);
    case 'late': return doLate(H, U);
    case 'probe': return doProbe(H, U);
  }
}

async function doLink(H, U, login) {
  const o = U.o, rng = H.rng;
  const before = await snap(U);
  const uname = login.name;
  const have = new Set(o.plants.map((p) => p.id));
  const fresh = login.plants.filter((id) => !have.has(id)).sort((a, b) => a - b);
  // app: ask the database whether the plan has room
  let chk = { ok: true, reason: null };
  if (fresh.length) {
    const r = await db.t(`select public.billing_may_link('${U.id}', '${uname}', array[${fresh.map((id) => H.inv.get(id)).join(',')}]::int[])`);
    if (!r.ok) { fail(ctxOf(H, U, 'link'), 'billing_may_link raised', r.err); return; }
    chk = { ok: r.v.ok, reason: r.v.reason ?? null };
  }
  const activeNow = o.active().length;
  // the oracle's view: which of these plants link stopped, and is there room for all of them?
  const plan = o.planLink(fresh);
  const noRoom = !o.comped && activeNow + fresh.length > cover(o.plan, o.held());
  if (fresh.length && noRoom === chk.ok) fail(ctxOf(H, U, 'link'), 'link: room check differs from the rules', { ok: chk.ok, rulesSayNoRoom: noRoom, plants: fresh, active: activeNow, extra: o.extra });
  // app: link. The database stops what the plan has no room for (0129 trigger). No payment at link time.
  const accRow = await db.json(`insert into private.sunsynk_accounts (user_id, sunsynk_username) values ('${U.id}', '${uname}') on conflict (user_id, sunsynk_username) do update set status = 'active' returning to_jsonb(id)`);
  const accId = accRow;
  if (fresh.length) {
    H.seq++;
    const ts = `timestamptz '2027-01-01 00:00:00+00' + interval '${H.seq} seconds'`;
    await db.exec(`insert into public.plant_users (plant_id, user_id, account_id, plant_name, linked_at) values ${fresh.map((id) => `(${id}, '${U.id}', '${accId}', 'Plant ${id}', ${ts})`).join(',')};`);
    const invRows = fresh.flatMap((id) => Array.from({ length: H.inv.get(id) }, (_, k) => `('SIM-${id}-${k}', ${id}, '${accId}')`));
    if (invRows.length) await db.exec(`insert into private.inverters (sn, plant_id, account_id) values ${invRows.join(',')} on conflict (sn) do update set account_id = excluded.account_id;`);
    await db.exec(`select public.billing_free_week_start('${U.id}', '${uname}');`);
    for (const pl of plan) o.plants.push({ id: pl.id, inv: H.inv.get(pl.id), seq: H.seq, paused: pl.paused, acc: accId });
    o.ticks = plan.ticks;
    // the rest of the login's plants are on it too (already linked via another login): nothing to do
  }
  U.accts.set(uname, accId);
  U.plantLogin ??= new Map();
  for (const id of login.plants) U.plantLogin.set(id, accId);
  await check(H, U, 'link');
}

// open a charge as the app does, decide how the payment goes, report it, compare with the oracle
async function payFlow(H, U, { plan, period, extras = null, label }) {
  const o = U.o, rng = H.rng, today = H.today;
  const before = await snap(U);
  const exp = o.quote(plan, period, extras, today);
  const r = await db.t(`select public.billing_charge_open(p_user => '${U.id}', p_plan => '${plan}', p_period => ${sq(period)}, p_extra => ${extras ?? 'null'})`);
  const ctx = ctxOf(H, U, label);
  inc(cov.events, 'charge_open');
  if (exp.err) {
    if (r.ok) { fail(ctx, `${label}: allowed but the rules refuse (${exp.err})`, r.v); await resyncUser(U, await snap(U)); return; }
    if (!r.err.includes(exp.err.split(' ').slice(0, 2).join(' ')) && !r.err.toLowerCase().includes(exp.err.toLowerCase().slice(0, 12))) fail(ctx, `${label}: refused for another reason`, { got: r.err, want: exp.err });
    inc(cov.refused, label);
    await sameState(H, U, label, before);
    return;
  }
  if (!r.ok) { fail(ctx, `${label}: refused but the rules allow it`, { err: r.err, want: exp }); return; }
  inc(cov.allowed, label);
  const amount = r.v.amount;
  if (amount !== exp.amount) fail(ctx, `${label}: charge amount differs from the rules (${exp.kind})`, { got: amount, want: exp.amount, kind: exp.kind, plan, period: exp.period, added: exp.added, extras, plants: o.plants.map((p) => [p.id, p.inv, p.paused ? 's' : 'a']), next: o.next, day: o.day, today, cyclePos: o.next ? cyclePos(today, o.next, o.period, o.day) : null });
  if (amount < 0) fail(ctx, 'charge negative', amount);
  inc(cov.charges, exp.kind);
  if (o.next && exp.kind === 'upgrade') cov.cycle[Math.min(9, Math.floor(cyclePos(today, o.next, o.period, o.day) * 10 / (dayNo(o.next) - dayNo(step(o.next, o.period, o.day, -1)) + 1)))]++;
  const c = { kind: exp.kind, plan, period: exp.period, added: exp.added, extraTotal: exp.extraTotal, ref: r.v.reference, amount, want: exp.amount, status: 'pending',
    createdOn: today, billingDate: o.next };
  // zero-rand upgrades apply at once
  if (amount === 0) {
    c.status = 'paid';
    o.applyPaid(c, today, false);
    o.charges.push(c);
    await check(H, U, label);
    return;
  }
  const ref = r.v.reference;
  o.charges.push(c);
  const outcome = payOutcome(H, U);
  const reusable = rng.chance(0.9);
  const cardJson = reusable ? card(++H.ref) : JSON.stringify({ authorization_code: 'AUTH_x', reusable: false, last4: '0000', card_type: 'visa ' });
  if (outcome === 'declined') {
    const f = await db.t(`select public.billing_charge_failed('${ref}', 'declined')`);
    if (!f.ok) fail(ctx, 'billing_charge_failed raised', f.err);
    c.status = 'failed';
    await sameStateOk(H, U, label + ' declined', before);
    return;
  }
  if (outcome === 'abandon') { c.cardJson = cardJson; c.reusable = reusable; (U.pending ??= []).push(c); cov.pendingLate++; await sameStateOk(H, U, label + ' abandoned', before); return; }
  // a wrong amount from Paystack must be refused
  if (rng.chance(0.05)) {
    const bad = await db.t(`select public.billing_charge_paid('${ref}', null, false, ${amount * 100 + 100})`);
    if (bad.ok) fail(ctx, 'payment with the wrong amount accepted', bad.v);
    await sameStateOk(H, U, label + ' wrong amount', before);
  }
  await finishPay(H, U, c, cardJson, reusable, label, outcome === 'twice');
}
async function sameStateOk(H, U, what, before) { return sameState(H, U, what, before); }

async function finishPay(H, U, c, cardJson, reusable, label, twice) {
  const o = U.o, ctx = ctxOf(H, U, label), today = H.today;
  const withCents = H.rng.chance(0.5);
  const r = await db.t(`select public.billing_charge_paid('${c.ref}', '${cardJson}'::jsonb, false, ${withCents ? c.amount * 100 : 'null'})`);
  if (!r.ok) { fail(ctx, `${label}: billing_charge_paid raised`, r.err); await resyncUser(U, await snap(U)); return; }
  const applied = o.applyPaid(c, today, reusable);
  c.status = 'paid';
  if (r.v.applied === false) {
    if (applied) fail(ctx, `${label}: payment taken but not applied although the rules apply it`, r.v);
    c.refund = true; inc(cov.days, 'paid-not-applied');
  } else {
    if (!applied) fail(ctx, `${label}: payment applied although the account moved on`, r.v);
    else o.paidTotal += c.want ?? c.amount;
  }
  if (!applied) c.refund = true;
  if (twice) {
    const r2 = await db.t(`select public.billing_charge_paid('${c.ref}', null, false, null)`);
    if (!r2.ok || !r2.v.again) fail(ctx, 'second payment report is not a no-op', r2);
  }
  await check(H, U, label);
  // the saved card is read back by the status screen (last 4)
  const s = await snap(U);
  if (reusable && applied && s.card !== JSON.parse(cardJson).last4) fail(ctx, `${label}: reusable card not saved`, { got: s.card });
}

async function doUpgrade(H, U, { first, extras }) {
  const o = U.o, rng = H.rng;
  let plan, period = null;
  if (o.plan === 'free') {
    plan = rng.chance(0.55) ? 'family' : 'home';
    period = rng.chance(0.5) ? 'monthly' : 'yearly';
  } else {
    // any plan in either period (0155): Family in the period held, Family yearly, or the plan held
    // yearly (a switch, 0138)
    const k = rng.weighted({ held: 5, yearly: 3, switch: 2 });
    plan = k === 'switch' ? o.plan : 'family';
    period = k === 'held' ? null : 'yearly';
  }
  if (extras && o.plan !== 'family') return doProbe(H, U);
  if (extras && rng.chance(0.35)) return doLower(H, U);
  // the plans page sends the extra plants wanted in all (0129); now and then none, the same, or junk
  const held = o.held();
  const want = rng.weighted({ more: 6, same: 1, none: 2, junk: 1 });
  const n = want === 'more' ? held + rng.int(1, 3) : want === 'same' ? held : want === 'none' ? null : rng.pick([-1, 0]);
  await payFlow(H, U, { plan, period, extras: plan === 'family' ? n : null, label: first ? 'first payment' : extras ? 'extra plants' : 'upgrade' });
}

// fewer extra plants from the billing date, or the drop undone
async function doLower(H, U) {
  const o = U.o, rng = H.rng;
  const n = rng.int(0, o.extra + 1);
  const before = await snap(U);
  const exp = o.clone().bookExtras(n);
  const r = await db.u(U.id, `select public.api_billing_extras(${n})`);
  const ctx = ctxOf(H, U, 'lower extras');
  inc(cov.events, 'extras:' + (n < o.extra ? 'down' : n === o.extra ? 'undo' : 'up'));
  if (exp.err) {
    if (r.ok) { fail(ctx, `lower extras: allowed but the rules refuse (${exp.err})`, { n }); await resyncUser(U, await snap(U)); return; }
    if (!r.err.toLowerCase().includes(exp.err.toLowerCase().slice(0, 12))) fail(ctx, 'lower extras: refused for another reason', { got: r.err, want: exp.err });
    inc(cov.refused, 'lower'); await sameState(H, U, 'lower extras', before); return;
  }
  if (!r.ok) { fail(ctx, 'lower extras: refused but the rules allow it', { err: r.err, n, extra: o.extra }); return; }
  inc(cov.allowed, 'lower');
  o.bookExtras(n);
  await check(H, U, 'lower extras');
}

async function doBook(H, U) {
  const o = U.o, rng = H.rng;
  const plan = rng.weighted({ free: 3, home: 4, family: 4 });
  const period = plan === 'free' ? null : rng.pick([null, 'monthly', 'yearly']);
  const before = await snap(U);
  const exp = o.clone().bookChange(plan, period);
  const r = await db.u(U.id, `select public.api_billing_change('${plan}', ${sq(period)})`);
  const ctx = ctxOf(H, U, 'book change');
  inc(cov.events, 'book:' + (plan === 'free' ? 'cancel' : PLAN_RANK[plan] < PLAN_RANK[o.plan] ? 'downgrade' : PLAN_RANK[plan] === PLAN_RANK[o.plan] ? (period && period !== o.period ? 'switch' : 'revert') : 'up'));
  if (exp.err) {
    if (r.ok) { fail(ctx, `book change: allowed but the rules refuse (${exp.err})`, { plan, period }); await resyncUser(U, await snap(U)); return; }
    if (!r.err.toLowerCase().includes(exp.err.toLowerCase().slice(0, 14))) fail(ctx, 'book change: refused for another reason', { got: r.err, want: exp.err });
    inc(cov.refused, 'book'); await sameState(H, U, 'book change', before); return;
  }
  if (!r.ok) { fail(ctx, 'book change: refused but the rules allow it', { err: r.err, plan, period, plants: o.plants.map((p) => [p.id, p.paused, o.rm.has(p.id)]) }); return; }
  inc(cov.allowed, 'book');
  o.bookChange(plan, period);
  await check(H, U, 'book change');
}

async function doRemove(H, U) {
  const o = U.o, rng = H.rng;
  if (!o.plants.length) return;
  const useLogin = rng.chance(0.3) && o.plan !== 'free' && !o.comped && U.plantLogin;
  const before = await snap(U);
  const ctx = ctxOf(H, U, 'book removal');
  if (useLogin) {
    const accs = [...new Set([...U.plantLogin.entries()].filter(([id]) => o.has(id)).map(([, a]) => a))];
    if (!accs.length) return;
    const acc = rng.pick(accs);
    // Remove login deletes the login and its plants now, on every plan (0139).
    const ids = (await db.json(`select coalesce(jsonb_agg(plant_id), '[]') from public.plant_users where user_id = '${U.id}' and account_id = '${acc}'`));
    const r = await db.u(U.id, `select public.api_link_remove('${acc}')`);
    if (!r.ok) { fail(ctx, 'remove login: raised on a paid plan', r.err); return; }
    if (r.v.result !== 'removed') fail(ctx, 'remove login on a paid plan did not remove now', r.v);
    o.plants = o.plants.filter((p) => !ids.includes(p.id));
    ids.forEach((id) => { o.rm.delete(id); o.freeRm.delete(id); U.plantLogin.delete(id); });
    if (o.rm.size === 0) o.rmOn = null;
    inc(cov.allowed, 'remove login');
    await check(H, U, 'remove login');
    return;
  }
  const p = rng.pick(o.plants);
  const exp = o.clone().bookRemoval(p.id);
  const r = await db.t(`select to_jsonb(1) from (select public.billing_book_removal('${U.id}', ${p.id})) x`);
  if (exp.err) {
    if (r.ok) { fail(ctx, `book removal: allowed but the rules refuse (${exp.err})`, {}); await resyncUser(U, await snap(U)); return; }
    inc(cov.refused, 'removal'); await sameState(H, U, 'book removal', before); return;
  }
  if (!r.ok) { fail(ctx, 'book removal: refused', r.err); return; }
  inc(cov.allowed, 'removal');
  o.bookRemoval(p.id);
  await check(H, U, 'book removal');
}

async function doKeep(H, U) {
  const o = U.o;
  // booked for deletion, or stopped by a booked downgrade (0136)
  const ids = [...new Set([...o.rm, ...o.drops()])]; if (!ids.length) return doChange(H, U);
  const id = H.rng.pick(ids);
  const before = await snap(U);
  const exp = o.clone().keep(id);
  const r = await db.u(U.id, `select public.api_billing_keep(${id})`);
  const ctx = ctxOf(H, U, 'keep plant');
  if (exp.err) {
    if (r.ok) { fail(ctx, `keep: allowed but the rules refuse (${exp.err})`, { id }); await resyncUser(U, await snap(U)); return; }
    inc(cov.refused, 'keep'); await sameState(H, U, 'keep', before); return;
  }
  if (!r.ok) { fail(ctx, 'keep: refused', r.err); return; }
  inc(cov.allowed, 'keep'); o.keep(id);
  await check(H, U, 'keep plant');
}

// Tick a locked plant into an open place (0197).
async function doPick(H, U) {
  const o = U.o, rng = H.rng;
  if (!o.plants.length) return;
  const cand = o.plants.filter((p) => p.paused);
  const p = cand.length && rng.chance(0.9) ? rng.pick(cand) : rng.pick(o.plants);
  const before = await snap(U);
  const exp = o.clone().pick(p.id);
  const r = await db.u(U.id, `select public.api_plant_pick(array[${p.id}]::bigint[])`);
  const ctx = ctxOf(H, U, 'plant pick');
  if (exp.err) {
    if (r.ok) { fail(ctx, `plant pick: allowed but the rules refuse (${exp.err})`, {}); await resyncUser(U, await snap(U)); return; }
    inc(cov.refused, 'pick'); await sameState(H, U, 'plant pick', before); return;
  }
  if (!r.ok) { fail(ctx, 'plant pick: refused but the rules allow it', { err: r.err, plan: o.plan, comped: o.comped, active: o.active().length, ticks: [...o.ticks] }); await resyncUser(U, await snap(U)); return; }
  inc(cov.allowed, 'pick'); o.pick(p.id);
  await check(H, U, 'plant pick');
}

// One ticked plant out, one locked plant in: one per 90 days (0197).
async function doChange(H, U) {
  const o = U.o, rng = H.rng;
  if (!o.plants.length) return;
  const locked = o.plants.filter((p) => p.paused), ticked = [...o.ticks.keys()];
  const into = (locked.length && rng.chance(0.9) ? rng.pick(locked) : rng.pick(o.plants)).id;
  const out = ticked.length && rng.chance(0.9) ? rng.pick(ticked) : rng.pick(o.plants).id;
  const before = await snap(U);
  const exp = o.clone().change(out, into, H.today);
  const r = await db.u(U.id, `select public.api_plant_change(${out}, ${into})`);
  const ctx = ctxOf(H, U, 'plant change');
  if (exp.err) {
    if (r.ok) { fail(ctx, `plant change: allowed but the rules refuse (${exp.err})`, { out, into }); await resyncUser(U, await snap(U)); return; }
    inc(cov.refused, 'change'); await sameState(H, U, 'plant change', before); return;
  }
  if (!r.ok) { fail(ctx, 'plant change: refused but the rules allow it', { err: r.err, out, into, plan: o.plan, ticks: [...o.ticks], last: o.changedOn }); await resyncUser(U, await snap(U)); return; }
  inc(cov.allowed, 'change'); o.change(out, into, H.today);
  await check(H, U, 'plant change');
}

async function doCard(H, U) {
  const o = U.o;
  const before = await snap(U);
  const r = await db.t(`select public.billing_card_open('${U.id}')`);
  const ctx = ctxOf(H, U, 'change card');
  const allowed = o.plan !== 'free' && !o.comped;
  if (!allowed) { if (r.ok) fail(ctx, 'change card allowed on Free/comped', {}); else inc(cov.refused, 'card'); await sameState(H, U, 'change card', before); return; }
  if (!r.ok) { fail(ctx, 'change card refused on a paid plan', r.err); return; }
  inc(cov.allowed, 'card');
  if (r.v.amount !== 1) fail(ctx, 'card change is not R1', r.v);
  const ok = H.rng.chance(0.8);
  if (ok) {
    const cj = card(++H.ref);
    const p = await db.t(`select public.billing_charge_paid('${r.v.reference}', '${cj}'::jsonb, false, 100)`);
    if (!p.ok) { fail(ctx, 'card payment raised', p.err); return; }
    o.hasCard = true;
    const s = await snap(U);
    if (s.card !== JSON.parse(cj).last4) fail(ctx, 'card change: new card not saved', { got: s.card });
    if (s.b && (s.b.plan !== before.b.plan || s.b.next_billing_date !== before.b.next_billing_date)) fail(ctx, 'card change moved plan or date', {});
  } else {
    await db.t(`select public.billing_charge_failed('${r.v.reference}', 'declined')`);
  }
  await check(H, U, 'change card');
}

async function doSettle(H, U) {
  const o = U.o, rng = H.rng;
  const before = await snap(U);
  const r = await db.t(`select public.billing_settle_open('${U.id}')`);
  const ctx = ctxOf(H, U, 'settle');
  if (o.state !== 'past_due') { if (r.ok) fail(ctx, 'settle allowed when nothing is due', r.v); else inc(cov.refused, 'settle'); await sameState(H, U, 'settle', before); return; }
  if (!r.ok) { fail(ctx, 'settle refused while past due', r.err); return; }
  inc(cov.allowed, 'settle');
  const first = o.charges.find((c) => c.kind === 'renewal' && c.dueOn === o.pds);
  if (!first) { await resync(H); return; }
  if (r.v.amount !== first.amount) fail(ctx, 'settle amount differs from the failed renewal', { got: r.v.amount, want: first.amount });
  inc(cov.charges, 'settle');
  const c = { kind: 'settle', plan: first.plan, period: first.period, added: 0, extraTotal: null, ref: r.v.reference, amount: first.amount, status: 'pending', dueOn: first.dueOn };
  o.charges.push(c);
  const x = rng.chance(0.75) ? 'paid' : 'declined';
  if (x === 'declined') { await db.t(`select public.billing_charge_failed('${c.ref}', 'declined')`); c.status = 'failed'; await check(H, U, 'settle declined'); return; }
  await finishPay(H, U, c, card(++H.ref), true, 'settle', false);
}

// A payment that was left open comes in later (the card page finished after the user left).
async function doLate(H, U) {
  const o = U.o;
  const list = (U.pending || []).filter((c) => c.status === 'pending');
  // a failed renewal that Paystack reports as paid after all
  const failedRen = o.charges.filter((c) => c.kind === 'renewal' && c.status === 'failed' && c.ref);
  const pickFailed = failedRen.length && (!list.length || H.rng.chance(0.6));
  if (!list.length && !failedRen.length) return;
  if (pickFailed) {
    const c = H.rng.pick(failedRen);
    const ctx = ctxOf(H, U, 'late renewal payment');
    const wasPast = o.state === 'past_due', plan = o.plan;
    const r = await db.t(`select public.billing_charge_paid('${c.ref}', null, false, ${(c.dbAmount ?? c.amount) * 100})`);
    if (!r.ok) { fail(ctx, 'late renewal payment raised', r.err); return; }
    inc(cov.days, 'late renewal payment');
    c.status = 'paid';
    if (!(wasPast && plan !== 'free' && c.dueOn === o.pds)) {
      // the rules: money for a renewal that no longer applies is not applied, and is marked for refund
      if (r.v.applied !== false) fail(ctx, 'late renewal paid while the account is not past due: money taken, nothing applied or marked for refund', { plan, wasPast, charge: c.amount });
      c.refund = true;
      await resync(H);
    } else { o.state = 'active'; o.pds = null; o.paidTotal += c.amount; await check(H, U, 'late renewal payment'); }
    return;
  }
  const c = H.rng.pick(list);
  const ctx = ctxOf(H, U, 'late payment');
  c.status = 'late';
  const applied = o.applyPaid(c, H.today, c.reusable);
  const r = await db.t(`select public.billing_charge_paid('${c.ref}', '${c.cardJson}'::jsonb, false, ${c.amount * 100})`);
  if (!r.ok) { fail(ctx, 'late payment raised', r.err); await resync(H); return; }
  inc(cov.days, 'late payment');
  if (r.v.applied === false) { if (applied) fail(ctx, 'late payment not applied though the rules apply it', r.v); c.refund = true; }
  else { if (!applied) fail(ctx, 'late payment applied though the account moved on', r.v); else o.paidTotal += c.want ?? c.amount; }
  c.status = 'paid';
  await check(H, U, 'late payment');
}

// actions that must be refused
async function doProbe(H, U) {
  const o = U.o, rng = H.rng;
  const before = await snap(U);
  const k = rng.int(0, 5), ctx = ctxOf(H, U, 'probe ' + k);
  if (k === 0) { return payFlow(H, U, { plan: 'home', period: 'monthly', label: 'probe: open charge' }); }
  if (k === 1) return payFlow(H, U, { plan: 'family', period: 'monthly', label: 'probe: open family charge' });
  if (k === 2) { const r = await db.t(`select public.billing_charge_paid('psh_nonesuch', null, false, null)`); if (r.ok) fail(ctx, 'unknown reference accepted', r.v); inc(cov.refused, 'unknown ref'); return; }
  if (k === 3) return doBook(H, U);
  if (k === 4) { // the plan already held, nothing more: refused, and a booked change stays
    if (o.plan !== 'free') return payFlow(H, U, { plan: o.plan, period: null, label: 'probe: same plan' });
    return;
  }
  return doPick(H, U);
}

// ---- end of a user's run ------------------------------------------------------------------------------
async function finalChecks(H, U) {
  const o = U.o, ctx = ctxOf(H, U, 'end');
  await check(H, U, 'end of run');
  // money over the run: what was paid equals what the rules said was due
  const rows = await db.json(`select coalesce(jsonb_agg(to_jsonb(c) order by created_at), '[]') from private.billing_charges c where user_id = '${U.id}' and status = 'paid' and kind <> 'card'`);
  const paidDb = rows.filter((c) => !c.error).reduce((s, c) => s + c.amount, 0);
  const refundDb = rows.filter((c) => c.error).reduce((s, c) => s + c.amount, 0);
  if (paidDb !== o.paidTotal) fail(ctx, 'money: total paid differs from the sum of the rules\' charges', { db: paidDb, rules: o.paidTotal, charges: rows.map((c) => [c.kind, c.amount, c.error ? 'refund' : '']) });
  const refundWant = o.charges.filter((c) => c.refund).reduce((s, c) => s + c.amount, 0);
  if (refundDb !== refundWant) fail(ctx, 'money: refund-marked payments differ', { db: refundDb, rules: refundWant });
  // no charge above a full period with every plant the user ever had collecting
  const invAll = o.plants.reduce((s, p) => s + Math.max(1, p.inv), 0) + 300;
  for (const c of rows) { const cap = c.plan === 'home' ? price('home', c.period) : price('family', c.period, invAll); if (c.amount > cap) fail(ctx, 'charge above a full period of the new price', c); }
  cov.moneyTotal = (cov.moneyTotal || 0) + paidDb;
  for (const k of Object.keys(o.stat)) cov.run[k] = (cov.run[k] || 0) + o.stat[k];
  cov.unbooked += o.unbooked || 0;
  if (o.state === 'past_due') cov.pastDue++;
}

// ---- main ----------------------------------------------------------------------------------------------------
async function main() {
  const t0 = Date.now();
  await db.exec(SESSION_SQL);
  // Users in the sim's id range that are not the sim's (samples.mjs's ui-sample users): not leftovers.
  await db.exec(`create temp table if not exists kept as select id from auth.users where id::text like '00000000-0000-4000-8%' and email not like 'sim-%@sim.test';`);
  const pre = await db.json(`select jsonb_build_object('users', (select count(*) from auth.users), 'billing', (select count(*) from private.billing), 'today', pg_get_functiondef('private.billing_today'::regproc))`);
  console.log(`seed ${SEED}, households ${ONLY !== null ? '(only ' + ONLY + ')' : NH}, ${YEARS} years`);
  let regressFailed = 0;
  try {
    if (ONLY === null) {
      console.log('== fixed cases (regress.mjs) ==');
      const rr = await regress(db, { log: (l) => console.log('  ' + l) });
      regressFailed = rr.filter((r) => r.bad.length).length;
      console.log(`  ${rr.length - regressFailed} of ${rr.length} hold`);
    }
    for (let h = 0; h < (REGRESS_ONLY ? 0 : NH); h++) {
      if (ONLY !== null && +ONLY !== h) continue;
      await household(h);
      if (h % 20 === 19) process.stdout.write(`  ${h + 1} households, ${cov.users} users, ${((Date.now() - t0) / 1000).toFixed(0)}s, ${findings.size} finding kinds\n`);
    }
  } catch (e) { console.error(e); simErrors++; await db.run('rollback;'); }
  const post = await db.json(`select jsonb_build_object('users', (select count(*) from auth.users), 'billing', (select count(*) from private.billing), 'today', pg_get_functiondef('private.billing_today'::regproc), 'leftover', (select count(*) from auth.users where email like 'sim-%@sim.test')
      + (select count(*) from private.billing where user_id::text like '00000000-0000-4000-8%' and user_id not in (select id from pg_temp.kept))
      + (select count(*) from private.billing_charges where user_id::text like '00000000-0000-4000-8%' and user_id not in (select id from pg_temp.kept))
      + (select count(*) from public.plant_users where plant_id between 70000000 and 89999999)
      + (select count(*) from private.inverters where sn like 'SIM-%')
      + (select count(*) from private.sunsynk_accounts where sunsynk_username like 'sim-%@login.test')
      + (select count(*) from private.free_week_logins where sunsynk_username like 'sim-%@login.test')
      + (select count(*) from public.email_queue where user_id::text like '00000000-0000-4000-8%' and user_id not in (select id from pg_temp.kept)))`);
  db.close();
  const clean = post.today === pre.today && post.leftover === 0;

  console.log('\n== coverage ==');
  console.log(`households ${cov.households}, users ${cov.users}, steps ${H_STEPS()}, shared plants ${cov.sharedPlants}`);
  console.log('events          ', JSON.stringify(cov.events));
  console.log('allowed         ', JSON.stringify(cov.allowed));
  console.log('refused (correct)', JSON.stringify(cov.refused));
  console.log('charges         ', JSON.stringify(cov.charges), 'pending/late', cov.pendingLate);
  console.log('payment paths   ', JSON.stringify(cov.days));
  console.log('upgrade day-of-cycle deciles', JSON.stringify(cov.cycle));
  console.log('billing days    ', JSON.stringify(cov.billingDays));
  console.log('end plans       ', JSON.stringify(cov.endPlans), 'past_due at end', cov.pastDue);
  console.log('plants per user ', JSON.stringify(cov.plantsPerUser));
  const paths = Object.entries(cov.paths).sort((a, b) => b[1] - a[1]);
  console.log(`plan paths (${paths.length} distinct)`, JSON.stringify(Object.fromEntries(paths.slice(0, 14))));
  console.log('renewal engine  ', JSON.stringify(cov.run), '(retries = day 1/3/7 charges, toFree = fell to Free on day 8, removals = plants deleted on their date)');
  console.log(`plants un-booked from removal by a resume: ${cov.unbooked}`);
  console.log(`money moved in the run R${cov.moneyTotal}`);
  console.log(`\n== cleanup == sim rows left in any table: ${post.leftover}, billing_today() unchanged: ${post.today === pre.today}`);
  console.log(`\n== findings: ${findings.size} kinds ==`);
  for (const [sig, f] of [...findings.entries()].sort((a, b) => b[1].count - a[1].count)) {
    console.log(`- ${sig}  x${f.count}\n    replay: node scripts/billing-sim/sim.mjs --seed ${f.first.seed} --only ${f.first.household} --trace   (user ${f.first.user}, step ${f.first.step}, ${f.first.event}, ${f.first.date})\n    ${JSON.stringify(f.first.detail).slice(0, 600)}`);
  }
  console.log(`\nseconds ${((Date.now() - t0) / 1000).toFixed(0)}`);
  if (regressFailed) console.log(`\n== fixed cases failing: ${regressFailed} ==`);
  if (simErrors || !clean) { console.log('SIMULATOR ERROR or dirty cleanup'); process.exit(2); }
  process.exit(findings.size || regressFailed ? 1 : 0);
}
let _steps = 0; const H_STEPS = () => cov.events ? Object.values(cov.events).reduce((s, x) => s + x, 0) : 0;
main();
