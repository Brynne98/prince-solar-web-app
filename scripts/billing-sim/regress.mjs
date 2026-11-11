// Every billing bug found so far, replayed as a fixed case (SOLAR-264). sim.mjs runs these first;
// `node scripts/billing-sim/sim.mjs --regress` runs only these. Each case is one transaction that is
// rolled back. A case returns the problems it saw; none = fixed. The ids are the SOLAR-264 findings
// (F1-F10 from the first run, P1-P5 from the Paystack test-mode run).
// Charges are opened with named arguments, so the cases also run against the code before 0127.
// Since 0129 Family bought extra plants (room), R49 a plant: the X cases; per-inverter cases went.
// Since 0156 (SOLAR-371) Home is 2 plants, Family 5, and extra plants are no longer sold: those held
// are set with SQL (held), and cases that only bought extras went (X3, X5-X8, X12, X15, X16).
// A case marked net: true ("safety net" in the log) sets state with SQL that no app path, Paystack event
// or daily run makes (a card email, a delete list set by hand); it guards the database alone.

const UID = (n) => `00000000-0000-4000-9000-${String(n).padStart(12, '0')}`;
const PLANT = (n) => 9900000 + n;

export async function regress(db, { only = null, log = () => {} } = {}) {
  const results = [];
  for (const c of CASES) {
    if (only && !only.some((p) => c.id.startsWith(p))) continue;
    await db.exec(`begin;
set local lock_timeout = '30s';
create or replace function private.billing_today() returns date language sql stable as $$ select current_setting('sim.today')::date $$;
-- the oracle prices at list: offers closed (0145)
update private.offers set joins_until = date '2000-01-01';
create or replace function public.plant_bootstrap_kick(p_plant bigint) returns void language plpgsql as $$ begin return; end $$;
create or replace function private.plant_start_fill(p_plant bigint) returns void language plpgsql as $$ begin return; end $$;
select set_config('sim.today', '2027-03-10', true);`);
    let bad;
    try { bad = await c.run(kit(db)); }
    catch (e) { bad = ['case broke: ' + (e.message || e).split('\n')[0]]; }
    finally { await db.exec('rollback;'); }
    results.push({ id: c.id, title: c.title, bad });
    log(`${bad.length ? 'FAIL' : 'ok  '} ${c.id}${c.net ? ' (safety net)' : ''} ${c.title}${bad.length ? '\n       ' + bad.join('\n       ') : ''}`);
  }
  return results;
}

// ---- helpers, inside the case's transaction ----
function kit(db) {
  let n = 0;
  const K = {
    db,
    today: (d) => db.exec(`select set_config('sim.today', '${d}', true);`),
    // a user on a plan: free, home, family (paid via a start charge), or comped family
    async user(plan = 'free', { period = 'monthly', comped = false, card = true } = {}) {
      const id = UID(++n);
      await db.exec(`insert into auth.users (id, email, aud, role, confirmation_token, recovery_token, email_change_token_new, email_change)
                     values ('${id}', 'reg-${n}@sim.test', 'authenticated', 'authenticated', '', '', '', '');`);
      if (comped) await db.exec(`insert into private.billing (user_id, plan, comped) values ('${id}', 'family', true);`);
      else if (plan !== 'free') {
        const o = await K.open(id, plan, period);
        if (!o.ok) throw new Error('start refused: ' + o.err);
        const p = await db.t(`select public.billing_charge_paid('${o.v.reference}', ${card ? `'{"authorization_code":"AUTH_${n}","reusable":true,"last4":"4081"}'::jsonb` : 'null'}, true, null)`);
        if (!p.ok) throw new Error('start not paid: ' + p.err);
      }
      return id;
    },
    // plants linked as link-sunsynk links them: one insert, in plant id order; inv = inverter rows
    async link(uid, plants) {
      const acc = await db.json(`insert into private.sunsynk_accounts (user_id, sunsynk_username) values ('${uid}', 'reg-${uid.slice(-4)}-${++n}@login.test') returning to_jsonb(id)`);
      const sorted = plants.slice().sort((a, b) => a.id - b.id);
      await db.exec(`insert into public.plant_users (plant_id, user_id, account_id, plant_name, linked_at) values ${sorted.map((p) =>
        `(${p.id}, '${uid}', '${acc}', 'P${p.id}', timestamptz '2027-01-01' + interval '${++n} seconds')`).join(',')};`);
      const inv = sorted.flatMap((p) => Array.from({ length: p.inv ?? 1 }, (_, k) => `('REG-${p.id}-${k}', ${p.id}, '${acc}')`));
      if (inv.length) await db.exec(`insert into private.inverters (sn, plant_id, account_id) values ${inv.join(',')} on conflict (sn) do nothing;`);
      await db.exec(`select public.billing_free_week_start('${uid}', 'reg-${n}@login.test');`);
      return acc;
    },
    // extras: the extra plants wanted on Family in all
    // plants: the stopped plants the room is bought for (the app sends them, 0130)
    open: (uid, plan, period = null, extras = null, plants = null) => db.t(`select public.billing_charge_open(p_user => '${uid}', p_plan => '${plan}', p_period => ${period ? `'${period}'` : 'null'}${extras != null ? `, p_extra => ${extras}` : ''}${plants ? `, p_plants => array[${plants.join(',')}]::bigint[]` : ''})`),
    extras: (uid, n) => db.u(uid, `select public.api_billing_extras(${n})`),
    // extra plants held from before 0156, when they were sold
    held: (uid, n) => db.exec(`update private.billing set extra_plants = ${n} where user_id = '${uid}';`),
    due: async (uid) => Number((await db.exec(`select public.billing_amount_due('${uid}')`))[0]),
    paid: (ref, cents = null) => db.t(`select public.billing_charge_paid('${ref}', null, true, ${cents ?? 'null'})`),
    failed: (ref) => db.t(`select public.billing_charge_failed('${ref}', 'declined')`),
    active: async (uid) => Number((await db.exec(`select count(*) from public.plant_users where user_id = '${uid}' and not paused`))[0]),
    paused: async (uid, id) => (await db.exec(`select paused from public.plant_users where user_id = '${uid}' and plant_id = ${id}`))[0] === 't',
    row: (uid) => db.json(`select to_jsonb(b) from private.billing b where user_id = '${uid}'`),
    charge: (ref) => db.json(`select to_jsonb(c) from private.billing_charges c where reference = '${ref}'`),
    as: (uid, q) => db.u(uid, q),
    run: (d) => db.t(`select public.billing_run('${d}'::date)`),
    sql: (q) => db.exec(q),
  };
  return K;
}

const P = PLANT;
const CASES = [
  { id: 'F1a', title: 'Family books Home, then links 3 more: they link stopped, and 2 collect after the renewal', async run(K) {
    const bad = [], u = await K.user('family');
    await K.link(u, [{ id: P(1) }]);
    const b = await K.as(u, `select public.api_billing_change('home', null)`); if (!b.ok) return ['booking refused: ' + b.err];
    await K.link(u, [{ id: P(2) }, { id: P(3) }, { id: P(4) }]);
    if (await K.active(u) !== 2) bad.push(`after the link: ${await K.active(u)} collect, booked Home takes 2`);
    const r = await K.row(u); await K.today(r.next_billing_date); await K.run(r.next_billing_date);
    if (await K.active(u) !== 2) bad.push(`after the renewal: ${await K.active(u)} collect on Home`);
    return bad;
  } },
  { id: 'F1b', title: 'Home cancels, then plants collect anyway: the renewal leaves 1, not the one booked for deletion', async run(K) {
    const bad = [], u = await K.user('family');
    await K.link(u, [{ id: P(1) }, { id: P(2) }]);
    await K.db.t(`select to_jsonb(1) from (select public.billing_book_removal('${u}', ${P(1)})) x`);
    const b = await K.as(u, `select public.api_billing_change('free', null)`); if (!b.ok) return ['cancel refused: ' + b.err];
    // a plant started outside the rules (as before 0127): the renewal must still fit the plan
    await K.sql(`alter table public.plant_users disable trigger plant_users_plan_limit; insert into public.plant_users (plant_id, user_id, plant_name, linked_at) values (${P(3)}, '${u}', 'x', '2027-02-01'); alter table public.plant_users enable trigger plant_users_plan_limit;`);
    const r = await K.row(u); await K.today(r.next_billing_date); await K.run(r.next_billing_date);
    if (await K.active(u) !== 1) bad.push(`${await K.active(u)} collect on Free after the date`);
    if (await K.paused(u, P(2))) bad.push('the kept plant stopped, the one booked for deletion was kept');
    return bad;
  } },
  { id: 'F2', title: 'Free (no billing row): starting stopped plants one after another stops at 1', async run(K) {
    const u = await K.user('free');
    await K.link(u, [{ id: P(1) }, { id: P(2) }, { id: P(3) }]);
    await K.as(u, `select public.api_plant_stop(${P(1)})`);
    for (const p of [1, 2, 3]) await K.as(u, `select public.api_plant_start(${P(p)})`);
    return (await K.active(u)) === 1 ? [] : [`${await K.active(u)} collect on Free`];
  } },
  { id: 'F3', title: 'Family: a 6th plant inserted as a link inserts it (no app pause) links stopped', async run(K) {
    const u = await K.user('family');
    await K.link(u, [1, 2, 3, 4, 5].map((i) => ({ id: P(i) })));
    await K.link(u, [{ id: P(6), inv: 2 }]);
    return (await K.paused(u, P(6))) ? [] : ['6th plant collects unpaid'];
  } },
  { id: 'F4', title: 'Family: a plant booked for removal still counts; a new plant past it links stopped', async run(K) {
    const bad = [], u = await K.user('family');
    await K.link(u, [1, 2, 3, 4, 5].map((i) => ({ id: P(i) })));
    await K.db.t(`select to_jsonb(1) from (select public.billing_book_removal('${u}', ${P(1)})) x`);
    const m = await K.db.t(`select public.billing_may_link('${u}', 'x', array[2])`);
    if (!m.ok || m.v.ok !== false) bad.push(`link check says room: ${JSON.stringify(m.v ?? m.err)}`);
    await K.link(u, [{ id: P(6), inv: 2 }]);
    if (!(await K.paused(u, P(6)))) bad.push('new plant collects unpaid');
    return bad;
  } },
  { id: 'F11', title: 'booked Home, stopped plants booked for deletion: starting all of them keeps 1 past the date', async run(K) {
    const u = await K.user('family');
    await K.link(u, [{ id: P(1) }, { id: P(2) }, { id: P(3) }]);
    for (const p of [1, 2, 3]) await K.as(u, `select public.api_plant_stop(${P(p)})`);
    for (const p of [1, 2]) await K.db.t(`select to_jsonb(1) from (select public.billing_book_removal('${u}', ${P(p)})) x`);
    await K.as(u, `select public.api_billing_change('home', null)`);
    // P1 and P2 collect on Family until their date; of the plants kept, Home's 1 only
    for (const p of [1, 2, 3]) await K.as(u, `select public.api_plant_start(${P(p)})`);
    const kept = Number((await K.sql(`select count(*) from public.plant_users where user_id = '${u}' and not paused and plant_id not in (${P(1)}, ${P(2)})`))[0]);
    return kept === 1 ? [] : [`${kept} kept plants collect with Home booked`];
  } },
  { id: 'F6', title: 'a failed renewal paid late, after it was settled: marked for refund, nothing applied', async run(K) {
    const bad = [], u = await K.user('home');
    const r = await K.row(u); await K.today(r.next_billing_date);
    const run = await K.run(r.next_billing_date);
    // other users on the local stack renew in the same run: take this user's charge
    const ren = await K.db.json(`select jsonb_build_object('reference', reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
    if (!run.ok || !ren) return ['no renewal charge: ' + JSON.stringify(run.err)];
    await K.failed(ren.reference);
    const s = await K.db.t(`select public.billing_settle_open('${u}')`); if (!s.ok) return ['settle refused: ' + s.err];
    await K.paid(s.v.reference);
    const late = await K.paid(ren.reference);
    if (!late.ok || late.v.applied !== false) bad.push('late renewal applied: ' + JSON.stringify(late.v ?? late.err));
    const c = await K.charge(ren.reference); if (!/^refund/.test(c.error || '')) bad.push('not marked for refund');
    return bad;
  } },
  { id: 'F6b', title: 'a renewal paid after the account fell to Free: marked for refund', async run(K) {
    const bad = [], u = await K.user('home', { card: false });
    const r = await K.row(u); const d = r.next_billing_date;
    await K.today(d); await K.run(d);
    const ref = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal' order by created_at limit 1`);
    for (const k of [1, 3, 7, 8]) { const x = new Date(Date.parse(d) + k * 864e5).toISOString().slice(0, 10); await K.today(x); await K.run(x); }
    if ((await K.row(u)).plan !== 'free') return ['did not fall to Free'];
    const late = await K.paid(ref);
    if (!late.ok || late.v.applied !== false) bad.push('applied on Free: ' + JSON.stringify(late.v ?? late.err));
    return bad;
  } },
  { id: 'F7', title: 'an upgrade opened on the last day and paid after the renewal: refund, plan stays', async run(K) {
    const bad = [], u = await K.user('home');
    const r = await K.row(u); const last = new Date(Date.parse(r.next_billing_date) - 864e5).toISOString().slice(0, 10);
    await K.today(last);
    const o = await K.open(u, 'family'); if (!o.ok) return ['refused: ' + o.err];
    await K.today(r.next_billing_date); await K.run(r.next_billing_date);
    const p = await K.paid(o.v.reference);
    if (!p.ok || p.v.applied !== false) bad.push(`R${o.v.amount} upgrade applied after the renewal`);
    if ((await K.row(u)).plan !== 'home') bad.push('plan became ' + (await K.row(u)).plan);
    return bad;
  } },
  { id: 'F8b', title: 'paid link then cancel: the account has a free week on record, so Free trims it', async run(K) {
    const u = await K.user('home');
    await K.link(u, [{ id: P(1) }]);
    const n = Number((await K.db.exec(`select count(*) from private.free_week_logins where user_id = '${u}'`))[0]);
    return n === 1 ? [] : ['no free-week row: never trimmed on Free'];
  } },
  { id: 'F8c', title: 'a same-plan charge with nothing to buy is refused and keeps a booked change', async run(K) {
    const u = await K.user('family');
    await K.link(u, [{ id: P(1) }]);
    await K.as(u, `select public.api_billing_change('home', null)`);
    const o = await K.open(u, 'family');
    const r = await K.row(u);
    if (o.ok) return [`same plan, nothing to buy: opened ${JSON.stringify(o.v)}`];
    return r.next_plan === 'home' ? [] : [`booked Home cleared (open: ${JSON.stringify(o.v ?? o.err)})`];
  } },
  { id: 'F9', title: 'comped Family: a 4th and 5th plant start and link with no limit', async run(K) {
    const bad = [], u = await K.user('family', { comped: true });
    await K.link(u, [{ id: P(1) }, { id: P(2) }, { id: P(3) }, { id: P(4) }]);
    await K.as(u, `select public.api_plant_stop(${P(4)})`);
    const s = await K.as(u, `select public.api_plant_start(${P(4)})`);
    if (!s.ok) bad.push('start refused: ' + s.err);
    await K.link(u, [{ id: P(5), inv: 3 }]);
    if (await K.active(u) !== 5) bad.push(`${await K.active(u)} of 5 collect`);
    return bad;
  } },
  { id: 'F10', title: 'the plan with a booked cancel: status says it ends (no charge on the date)', async run(K) {
    const u = await K.user('home');
    await K.as(u, `select public.api_billing_change('free', null)`);
    const st = await K.as(u, `select public.api_billing_status()`);
    return st.v.nextPlan === 'free' && st.v.nextAmount === 0 ? [] : [JSON.stringify(st.v)];
  } },
  { id: 'C457', title: 'paid switch to yearly, then cancel: the year starts as paid, the plan ends a year later; Keep goes back to the switch (0175, 0176)', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date, yr = (+d.slice(0, 4) + 1) + d.slice(4); // the same day a year on
    const o = await K.open(u, 'home', 'yearly'); if (!o.ok) return ['switch refused: ' + o.err];
    const p = await K.paid(o.v.reference); if (!p.ok) return ['switch not paid: ' + p.err];
    const c = await K.as(u, `select public.api_billing_change('free', null)`);
    if (!c.ok) return ['cancel in the paid year: ' + c.err];
    if (c.v.nextPlan !== 'free' || c.v.prepaidOn !== d) bad.push(`after cancel: nextPlan ${c.v.nextPlan}, prepaidOn ${c.v.prepaidOn}`);
    const mail = await K.db.json(`select data from public.email_queue where user_id = '${u}' and kind = 'bill_change' order by created_at desc limit 1`);
    if (mail?.on !== yr) bad.push(`cancel email says it ends ${mail?.on}, want ${yr}`);
    // Keep, tapped twice: back to the paid switch, one plan-kept email for the year after it (0176)
    for (let i = 0; i < 2; i++) {
      const undo = await K.as(u, `select public.api_billing_change('home', 'monthly')`);
      if (!undo.ok) { bad.push(`undo ${i + 1} in the paid year: ${undo.err}`); break; }
      if (undo.v.nextPlan || undo.v.prepaidOn !== d || undo.v.nextPeriod !== 'yearly') bad.push(`after undo ${i + 1}: ${JSON.stringify([undo.v.nextPlan, undo.v.nextPeriod, undo.v.prepaidOn])}`);
    }
    const kept = await K.db.json(`select coalesce(jsonb_agg(data), '[]') from public.email_queue where user_id = '${u}' and kind = 'bill_kept'`);
    if (kept.length !== 1 || kept[0].on !== yr || kept[0].period !== 'yearly') bad.push('plan-kept emails: ' + JSON.stringify(kept));
    const again = await K.as(u, `select public.api_billing_change('free', null)`);
    if (!again.ok) return [...bad, 'cancel again in the paid year: ' + again.err];
    // a second tab cancels too: nothing changes, no second email (0176)
    const twice = await K.as(u, `select public.api_billing_change('free', null)`);
    if (!twice.ok || twice.v.nextPlan !== 'free' || twice.v.prepaidOn !== d) bad.push('second cancel in the paid year: ' + (twice.ok ? JSON.stringify([twice.v.nextPlan, twice.v.prepaidOn]) : twice.err));
    const cancels = Number((await K.sql(`select count(*) from public.email_queue where user_id = '${u}' and kind = 'bill_change' and data->>'to' = 'free'`))[0]);
    if (cancels !== 2) bad.push(`${cancels} cancel emails for two cancels and a repeat`);
    // the paid room holds until the year starts: Home's 2 plants link collecting
    await K.link(u, [{ id: P(4571) }, { id: P(4572) }]);
    if (await K.active(u) !== 2) bad.push(`${await K.active(u)} of 2 plants collect in the paid year`);
    await K.today(d); await K.run(d);
    const r = await K.row(u);
    if (r.plan !== 'home' || r.period !== 'yearly' || r.prepaid_on || r.next_plan !== 'free' || r.next_billing_date !== yr) {
      bad.push(`on ${d}: ${r.plan} ${r.period}, prepaid_on ${r.prepaid_on}, next ${r.next_plan} on ${r.next_billing_date}`);
    }
    const renewals = Number((await K.sql(`select count(*) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`))[0]);
    if (renewals) bad.push(`${renewals} renewal charge(s) on a paid year`);
    await K.today(yr); await K.run(yr);
    if ((await K.row(u)).plan !== 'free') bad.push(`on ${yr}: still ${(await K.row(u)).plan}`);
    if (await K.active(u) !== 1) bad.push(`on ${yr}: ${await K.active(u)} plants collect on Free`);
    return bad;
  } },
  { id: 'C457b', title: 'a booked cancel takes no downgrade or upgrade until Keep; an upgrade paid after it goes back (0175, 0176)', async run(K) {
    const bad = [], u = await K.user('family');
    const early = await K.open(u, 'family', 'yearly');         // a switch opened before the cancel
    const c = await K.as(u, `select public.api_billing_change('free', null)`);
    if (!c.ok) return ['cancel refused: ' + c.err];
    for (const [what, q] of [['downgrade', `select public.api_billing_change('home', null)`],
                             ['period switch', `select public.api_billing_change('family', 'yearly')`]]) {
      const r = await K.as(u, q);
      if (r.ok || !/cancelled/.test(r.err)) bad.push(`${what} after cancel: ${r.ok ? 'allowed' : r.err}`);
    }
    const h = await K.user('home');
    await K.as(h, `select public.api_billing_change('free', null)`);
    const up = await K.open(h, 'family');
    if (up.ok || !/cancelled/.test(up.err)) bad.push('upgrade after cancel: ' + (up.ok ? 'opened' : up.err));
    if (!early.ok) bad.push('switch before the cancel refused: ' + early.err);
    else {
      const p = await K.paid(early.v.reference);
      if (!p.ok || p.v.applied !== false) bad.push('a switch paid after the cancel was applied');
    }
    const r = await K.row(u);
    if (r.next_plan !== 'free' || r.prepaid_on) bad.push(`cancel lost: next ${r.next_plan}, prepaid_on ${r.prepaid_on}`);
    return bad;
  } },
  { id: 'C467', title: 'a second cancel changes nothing; Keep undoes a booked cancel: the plan renews on its date, one email each (0176)', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    const c = await K.as(u, `select public.api_billing_change('free', null)`);
    if (!c.ok) return ['cancel refused: ' + c.err];
    // a second tab cancels too: nothing changes, one cancel email (0176)
    const c2 = await K.as(u, `select public.api_billing_change('free', null)`);
    if (!c2.ok || c2.v.nextPlan !== 'free') bad.push('second cancel: ' + (c2.ok ? c2.v.nextPlan : c2.err));
    const mails = Number((await K.sql(`select count(*) from public.email_queue where user_id = '${u}' and kind = 'bill_change'`))[0]);
    if (mails !== 1) bad.push(`${mails} cancel emails for one cancel and a repeat`);
    // Keep, tapped twice
    for (let i = 0; i < 2; i++) {
      const k = await K.as(u, `select public.api_billing_change('home', 'monthly')`);
      if (!k.ok) return [`keep ${i + 1} refused: ${k.err}`];
      if (k.v.nextPlan || k.v.nextPeriod) bad.push(`after keep ${i + 1}: ${k.v.nextPlan} ${k.v.nextPeriod}`);
    }
    const kept = await K.db.json(`select coalesce(jsonb_agg(data), '[]') from public.email_queue where user_id = '${u}' and kind = 'bill_kept'`);
    if (kept.length !== 1 || kept[0].plan !== 'home' || kept[0].on !== d) bad.push('plan-kept emails: ' + JSON.stringify(kept));
    await K.today(d); await K.run(d);
    const r = await K.row(u);
    if (r.plan !== 'home' || r.next_billing_date <= d) bad.push(`on ${d}: ${r.plan}, next ${r.next_billing_date}`);
    const renewals = Number((await K.sql(`select count(*) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`))[0]);
    if (renewals !== 1) bad.push(`${renewals} renewal charge(s) on ${d}`);
    return bad;
  } },
  { id: 'P1', net: true, title: 'a saved card is charged with the email it was saved with', async run(K) {
    const u = await K.user('home');
    await K.sql(`update private.billing set card_email = 'old@sim.test' where user_id = '${u}'`);
    const o = await K.open(u, 'family');
    return o.ok && o.v.cardEmail === 'old@sim.test' ? [] : ['charge email: ' + (o.v?.cardEmail ?? o.v?.email ?? o.err)];
  } },
  { id: 'P3', title: 'a charge reference tells who opened it (verify answers only them)', async run(K) {
    const u = await K.user('free');
    const o = await K.open(u, 'home', 'monthly');
    const w = await K.db.t(`select to_jsonb(public.billing_charge_user('${o.v.reference}'))`);
    return w.ok && w.v === u ? [] : ['no owner check: ' + (w.err || w.v)];
  } },
  // ---- 0129: Family buys extra plants, R49 a plant (decided 2026-10-31) ----
  { id: 'X1', title: 'Family: a login with 7 plants fills 5, links 2 stopped, bill stays R199', async run(K) {
    const bad = [], u = await K.user('family');
    await K.link(u, [1, 2, 3, 4, 5, 6, 7].map((i) => ({ id: P(i), inv: 2 })));
    if (await K.active(u) !== 5) bad.push(`${await K.active(u)} collect, room is 5`);
    if (await K.due(u) !== 199) bad.push(`next bill R${await K.due(u)}`);
    return bad;
  } },
  { id: 'X2', title: 'extra plants are no longer sold (0156): more on Family is refused, an upgrade buys none', async run(K) {
    const bad = [], f = await K.user('family'), h = await K.user('home');
    const more = await K.open(f, 'family', null, 2);
    if (more.ok) bad.push('extras opened on Family: ' + JSON.stringify(more.v));
    else if (!/nothing to buy/.test(more.err)) bad.push('refused for another reason: ' + more.err);
    const up = await K.open(h, 'family', null, 2); if (!up.ok) return [...bad, 'upgrade refused: ' + up.err];
    if (up.v.amount !== 100) bad.push(`upgrade on day 1 charged R${up.v.amount}, R199 less R99 is R100`);
    await K.paid(up.v.reference);
    if ((await K.row(h)).extra_plants !== 0) bad.push(`upgrade bought ${(await K.row(h)).extra_plants} extras`);
    if (await K.due(h) !== 199) bad.push(`next bill R${await K.due(h)}, want R199`);
    return bad;
  } },
  { id: 'X4', title: 'extras held: lowering waits for the billing date; with 7 collecting it books and the last linked stops on the date (0136)', async run(K) {
    const bad = [], u = await K.user('family');
    await K.held(u, 2);
    await K.link(u, [1, 2, 3, 4, 5, 6, 7].map((i) => ({ id: P(i) })));
    const l = await K.extras(u, 1); if (!l.ok) return ['lowering with 7 collecting refused: ' + l.err];
    if ((await K.row(u)).extra_plants !== 2) bad.push('lowered at once');
    if (await K.due(u) !== 248) bad.push(`next bill R${await K.due(u)}, want R248`);
    if (await K.active(u) !== 7) bad.push(`${await K.active(u)} collect before the date, want 7`);
    const r = await K.row(u); await K.today(r.next_billing_date); await K.run(r.next_billing_date);
    const after = await K.row(u);
    if (after.extra_plants !== 1 || after.next_extra_plants !== null) bad.push(`after the date: ${after.extra_plants} extras, ${after.next_extra_plants} booked`);
    if (await K.active(u) !== 6) bad.push(`${await K.active(u)} collect after the date`);
    return bad;
  } },
  { id: 'X9', title: 'extras held, Home booked: buying more is refused; the renewal to Home drops them', async run(K) {
    const bad = [], u = await K.user('family');
    await K.held(u, 1);
    await K.as(u, `select public.api_billing_change('home', null)`);
    if ((await K.open(u, 'family', null, 2)).ok) bad.push('extras bought with Home booked');
    if (await K.due(u) !== 99) bad.push(`next bill R${await K.due(u)}, Home is R99`);
    const r = await K.row(u); await K.today(r.next_billing_date); await K.run(r.next_billing_date);
    if ((await K.row(u)).extra_plants !== 0) bad.push('extras kept on Home');
    return bad;
  } },
  { id: 'X10', title: 'extras by the user only on Family, never raised without paying', async run(K) {
    const bad = [], h = await K.user('home'), f = await K.user('family');
    if ((await K.extras(h, 0)).ok) bad.push('Home user booked extras');
    if ((await K.extras(f, 2)).ok) bad.push('raised without paying');
    if ((await K.open(f, 'family', null, -1)).ok) bad.push('negative extras opened');
    if ((await K.row(f)).extra_plants !== 0) bad.push('extras changed');
    return bad;
  } },
  { id: 'G7c', title: 'room held stays: stop the 6th, renew (still billed), start it again without paying', async run(K) {
    const bad = [], u = await K.user('family');
    await K.held(u, 1);
    await K.link(u, [1, 2, 3, 4, 5, 6].map((i) => ({ id: P(i) })));
    await K.as(u, `select public.api_plant_stop(${P(6)})`);
    const r = await K.row(u); await K.today(r.next_billing_date); await K.run(r.next_billing_date);
    const ren = await K.db.json(`select to_jsonb(amount) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
    if (ren !== 248) bad.push(`renewal R${ren}, want R248`);
    const s = await K.as(u, `select public.api_plant_start(${P(6)})`);
    if (!s.ok) bad.push('start refused: ' + s.err);
    return bad;
  } },
  { id: 'G9', title: 'day 8 to Free with 3 collecting: 1 stays, no error from the limit', async run(K) {
    const bad = [], u = await K.user('family', { card: false });
    await K.link(u, [{ id: P(1) }, { id: P(2) }, { id: P(3) }]);
    const d = (await K.row(u)).next_billing_date;
    for (const k of [0, 1, 3, 7, 8]) { const x = new Date(Date.parse(d) + k * 864e5).toISOString().slice(0, 10); await K.today(x); const r = await K.run(x); if (!r.ok) bad.push(`run ${x}: ${r.err}`); }
    if ((await K.row(u)).plan !== 'free') bad.push('not on Free');
    if (await K.active(u) !== 1 || await K.paused(u, P(1))) bad.push('first plant not the one kept');
    return bad;
  } },
  // ---- SOLAR-495 (0188): a cancel deletes on its end date; a failed payment keeps 30 days ----
  { id: 'E495a', title: 'Home with 2 plants cancels: warned 3 days before; on the end date 1 stays, the other is deleted, no 30 days kept', async run(K) {
    const bad = [], u = await K.user('home');
    await K.link(u, [{ id: P(1) }, { id: P(2) }]);
    const c = await K.as(u, `select public.api_billing_change('free', null)`); if (!c.ok) return ['cancel refused: ' + c.err];
    const end = (await K.row(u)).next_billing_date;
    const mail = await K.db.json(`select data from public.email_queue where user_id = '${u}' and kind = 'bill_change' order by id desc limit 1`);
    if (mail?.deleteOn !== end) bad.push(`cancel email deletes on ${mail?.deleteOn}, not the end date ${end}`);
    const ls = await K.as(u, `select coalesce(jsonb_agg(p), '[]') from public.api_link_status() s, jsonb_array_elements(s.plants) p`);
    const drop = (ls.v || []).find((p) => p.drop);
    if (drop?.remove_on !== end) bad.push(`Billing dates the drop ${drop?.remove_on}, not ${end}`);
    const d3 = addD(end, -3); await K.today(d3); await K.run(d3);
    const soon = await K.db.json(`select data from public.email_queue where user_id = '${u}' and kind = 'bill_cancel_soon'`);
    if (soon?.on !== end || soon?.from !== 'home') bad.push(`3-day email: ${JSON.stringify(soon)}`);
    await K.today(end); await K.run(end);
    const r = await K.row(u);
    if (r.plan !== 'free') bad.push('not on Free');
    if (r.keep_until !== null) bad.push(`keep_until ${r.keep_until}: history kept after a cancel`);
    if (r.remove_on !== null || (r.plants_to_remove || []).length) bad.push(`still booked: ${r.plants_to_remove} on ${r.remove_on}`);
    const left = await K.db.json(`select coalesce(jsonb_agg(plant_id), '[]') from public.plant_users where user_id = '${u}'`);
    if (left.length !== 1 || left[0] !== P(1)) bad.push(`plants left: ${JSON.stringify(left)}`);
    const wb = await K.db.json(`select data from public.email_queue where user_id = '${u}' and kind = 'winback'`);
    if (!wb || 'keepUntil' in wb || !('days' in wb)) bad.push(`plan-ended email: ${JSON.stringify(wb)}`);
    return bad;
  } },
  { id: 'E495b', title: 'a failed payment\'s move to Free still keeps 30 days: keep_until and the stopped plant\'s delete date', async run(K) {
    const bad = [], u = await K.user('home', { card: false });
    await K.link(u, [{ id: P(1) }, { id: P(2) }]);
    const d = (await K.row(u)).next_billing_date;
    let d8;
    for (const k of [0, 1, 3, 7, 8]) { d8 = addD(d, k); await K.today(d8); const x = await K.run(d8); if (!x.ok) bad.push(`run ${d8}: ${x.err}`); }
    const r = await K.row(u);
    if (r.plan !== 'free') return [...bad, 'not on Free'];
    if (r.keep_until !== addD(d8, 30)) bad.push(`keep_until ${r.keep_until}, not ${addD(d8, 30)}`);
    if (r.remove_on !== addD(d8, 30) || !(r.plants_to_remove || []).includes(P(2))) bad.push(`stopped plant: ${r.plants_to_remove} on ${r.remove_on}`);
    if (await K.db.json(`select to_jsonb(count(*)) from public.email_queue where user_id = '${u}' and kind in ('winback', 'bill_cancel_soon')`) !== 0) bad.push('cancel emails sent for a failed payment');
    return bad;
  } },
  // ---- SOLAR-264 second pass: the daily run, refund events, paid plants that do not start ----
  { id: 'A1', title: 'a renewal the run handed out but never reported: offered again with its reference, not failed', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    await K.today(d); await K.run(d);
    const ref = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
    if (!ref) return ['no renewal charge'];
    const d1 = addD(d, 1); await K.today(d1);
    const run = await K.run(d1);
    if (!run.ok) return ['run raised: ' + run.err];
    const c = await K.charge(ref);
    if (c.status !== 'pending') bad.push(`charge ${c.status} (${c.error}): never charged, reported failed`);
    if (!(run.v || []).some((x) => x.reference === ref)) bad.push('not handed out again');
    if ((await K.row(u)).state !== 'active') bad.push('account past due for a card never charged');
    const mails = Number((await K.sql(`select count(*) from public.email_queue where user_id = '${u}' and kind = 'bill_failed'`))[0]);
    if (mails) bad.push(`${mails} "payment failed" emails`);
    return bad;
  } },
  { id: 'A2', title: 'a renewal not reached on its day, declined the next: tries on day 1, 3, 7 only, Free on day 8', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    for (let k = 0; k <= 8; k++) {
      const x = addD(d, k); await K.today(x); const r = await K.run(x);
      if (!r.ok) { bad.push(`run day ${k}: ${r.err}`); continue; }
      // day 0's charge is handed out and lost (the run stopped); every later one is declined
      if (k > 0) for (const c of (r.v || [])) { const own = await K.charge(c.reference); if (own?.user_id === u) await K.failed(c.reference); }
    }
    const tries = await K.db.json(`select coalesce(jsonb_agg(jsonb_build_object('on', created_on, 'error', error) order by created_on), '[]') from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
    const days = tries.map((t) => (Date.parse(t.on) - Date.parse(d)) / 864e5);
    if (JSON.stringify(days) !== '[1,3,7]') bad.push(`card tried on days ${days.join(', ')}, want 1, 3, 7`);
    if (tries.some((t) => /^not charged/.test(t.error || ''))) bad.push('a charge never made was reported failed');
    if ((await K.row(u)).plan !== 'free') bad.push('not on Free on day 8');
    return bad;
  } },
  { id: 'A3', title: 'a day-7 retry not reached: day 8 tries it before Free, Free once it fails', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    for (const k of [0, 1, 3, 7]) {
      const x = addD(d, k); await K.today(x); const r = await K.run(x);
      if (k < 7) for (const c of (r.v || [])) { const own = await K.charge(c.reference); if (own?.user_id === u) await K.failed(c.reference); }
    }
    const d8 = addD(d, 8); await K.today(d8);
    const r = await K.run(d8);
    const mine = [];
    for (const c of (r.v || [])) { const own = await K.charge(c.reference); if (own?.user_id === u) mine.push(c.reference); }
    if ((await K.row(u)).plan === 'free') bad.push('on Free before the day-7 try was made');
    if (mine.length !== 1) bad.push(`day 8 hands out ${mine.length} charges, want the day-7 one`);
    for (const ref of mine) await K.failed(ref);
    await K.run(d8);
    if ((await K.row(u)).plan !== 'free') bad.push('not on Free after the last try failed');
    return bad;
  } },
  { id: 'B1', title: 'a refund Paystack accepts and later refuses is recorded on the charge', async run(K) {
    const bad = [], u = await K.user('home');
    const o = await K.db.t(`select public.billing_card_open('${u}')`); if (!o.ok) return ['card change refused: ' + o.err];
    await K.db.t(`select public.billing_charge_paid('${o.v.reference}', '{"authorization_code":"AUTH_NEW","reusable":true,"last4":"1111"}'::jsonb, true, null)`);
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${o.v.reference}', null)) x`);
    const e = await K.db.t(`select to_jsonb(public.billing_charge_refund_event('${o.v.reference}', 'failed', 'Declined by issuer'))`);
    if (!e.ok) bad.push('refund event not taken: ' + e.err);
    const c = await K.charge(o.v.reference);
    if (!/^refund failed: Declined by issuer/.test(c.error || '')) bad.push(`charge error: ${c.error}`);
    return bad;
  } },
  { id: 'F12', title: 'paid room, a stopped plant that fits it refuses to start: charge marked for refund, nothing applied', async run(K) {
    const bad = [], u = await K.user('home');
    await K.link(u, [{ id: P(1) }, { id: P(2) }, { id: P(3) }]);   // P3 links stopped: no room on Home
    const o = await K.open(u, 'family', null, null, [P(3)]); if (!o.ok) return ['refused: ' + o.err];
    // a refusal the paid re-check did not foresee
    await K.sql(`create function public.sim_refuse_p3() returns trigger language plpgsql as $f$ begin
        if new.plant_id = ${P(3)} and not new.paused then raise exception 'no room' using errcode = '22023'; end if; return new; end $f$;
      create trigger sim_refuse_p3 before update of paused on public.plant_users for each row execute function public.sim_refuse_p3();`);
    const p = await K.paid(o.v.reference, o.v.amount * 100);
    if (!p.ok) return ['paid raised: ' + p.err];
    if (p.v.applied !== false) bad.push('reported applied, plant stopped');
    const c = await K.charge(o.v.reference);
    if (!/^refund/.test(c.error || '')) bad.push('not marked for refund');
    if ((await K.row(u)).plan !== 'home') bad.push(`plan became ${(await K.row(u)).plan}`);
    if (!(await K.paused(u, P(3)))) bad.push('plant started');
    return bad;
  } },
  { id: 'A4', title: 'a retry left open, then the user settles with another card: the run does not charge it again', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    await K.today(d); let r = await K.run(d);
    for (const c of (r.v || [])) { const own = await K.charge(c.reference); if (own?.user_id === u) await K.failed(c.reference); }
    const d1 = addD(d, 1); await K.today(d1); r = await K.run(d1);   // day-1 retry handed out, no answer
    const s = await K.db.t(`select public.billing_settle_open('${u}')`); if (!s.ok) return ['settle refused: ' + s.err];
    await K.paid(s.v.reference);
    const d2 = addD(d, 2); await K.today(d2); r = await K.run(d2);
    const mine = [];
    for (const c of (r.v || [])) { const own = await K.charge(c.reference); if (own?.user_id === u) mine.push(c.reference); }
    if (mine.length) bad.push('the settled retry is charged again');
    if ((await K.row(u)).state !== 'active') bad.push('past due again after paying');
    const mails = Number((await K.sql(`select count(*) from public.email_queue where user_id = '${u}' and kind = 'bill_failed'`))[0]);
    if (mails !== 1) bad.push(`${mails} "payment failed" emails, want 1 (the real decline)`);
    return bad;
  } },
  { id: 'A5', title: 'a renewal Paystack keeps open: handed out for 2 more days, failed on the 3rd', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    let ref = null;
    for (let k = 0; k <= 3; k++) {
      const x = addD(d, k); await K.today(x); await K.run(x);
      ref ??= await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
      const c = await K.charge(ref);
      if (k < 3 && c.status !== 'pending') { bad.push(`day ${k}: ${c.status} (${c.error})`); break; }
      if (k === 3 && c.status !== 'failed') bad.push(`day 3: still ${c.status}`);
    }
    if ((await K.row(u)).state !== 'past_due') bad.push('not past due after 3 days open');
    return bad;
  } },
  { id: 'B2', title: 'a payment marked for refund is refunded like the R1: the refund is dated, its reason kept', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    await K.today(d); await K.run(d);
    const ref = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
    await K.failed(ref);
    const s = await K.db.t(`select public.billing_settle_open('${u}')`); if (!s.ok) return ['settle refused: ' + s.err];
    await K.paid(s.v.reference);
    const late = await K.paid(ref);                       // paid twice for one date: marked for refund
    if (!late.ok || late.v.applied !== false) return ['not marked: ' + JSON.stringify(late.v ?? late.err)];
    const r = await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${ref}', null)) x`);
    if (!r.ok) bad.push('refund not recorded: ' + r.err);
    let c = await K.charge(ref);
    if (!c.refunded_at) bad.push('refund not dated');
    if (!/^refund: /.test(c.error || '')) bad.push(`reason lost: ${c.error}`);
    // a refund Paystack refuses at once keeps the reason too
    const late2 = await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${s.v.reference}', 'not ours to refund')) x`);
    c = await K.charge(s.v.reference);
    if (c.refunded_at || (c.error || '').startsWith('refund failed')) bad.push('a payment that applied was touched by a refund');
    return late2.ok ? bad : [...bad, late2.err];
  } },
  // ---- round 3 (2026-10-31): Brynne's added scenarios ----
  { id: 'D1', title: 'account delete is refused while a paid plan runs and is not cancelled', async run(K) {
    const u = await K.user('home');
    const r = await K.as(u, `select public.api_account_delete()`);
    return r.ok ? ['api_account_delete deleted an active Home account (billing row and charges gone with it)'] : [];
  } },
  { id: 'D2', title: 'account delete is refused while money is owed: past due, even with a cancel booked', async run(K) {
    const u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    await K.today(d); await K.run(d);
    const ref = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
    await K.failed(ref);
    await K.sql(`update private.billing set next_plan = 'free' where user_id = '${u}'`);  // as the app books it
    const r = await K.as(u, `select public.api_account_delete()`);
    return r.ok ? ['deleted while past due: the failed renewal is gone with the account'] : [];
  } },
  { id: 'D3', title: 'account delete with a card page open is refused (an open payment is money owed)', async run(K) {
    const u = await K.user('home');
    const o = await K.open(u, 'family'); if (!o.ok) return ['open refused: ' + o.err];
    await K.sql(`update private.billing set next_plan = 'free' where user_id = '${u}'`);  // cancel booked: the app allows delete
    const d = await K.as(u, `select public.api_account_delete()`);
    // Decided 2026-10-31: an open start, upgrade or settle is money owed, so delete waits.
    return d.ok ? ['deleted with a card page open: a later payment finds no charge'] : [];
  } },
  { id: 'E1', title: 'email changed while the card page is open: the card is saved with the email Paystack saw', async run(K) {
    const u = await K.user('free');
    const o = await K.open(u, 'home', 'monthly'); if (!o.ok) return ['open refused: ' + o.err];
    const sent = o.v.email;
    await K.sql(`update auth.users set email = 'changed-${u.slice(-4)}@sim.test' where id = '${u}'`);
    await K.db.t(`select public.billing_charge_paid('${o.v.reference}', '{"authorization_code":"AUTH_E1","reusable":true}'::jsonb, true, null)`);
    const r = await K.row(u);
    return r.card_email === sent ? [] : [`card_email ${r.card_email}, Paystack saved the card under ${sent}: every renewal is refused`];
  } },
  { id: 'M1', title: 'a missed run day: the day-3 retry still happens on the next run', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    let tries = 0;
    for (let k = 0; k <= 8; k++) {
      if (k === 3) continue;                         // pg_cron missed day 3
      const day = addD(d, k); await K.today(day);
      const r = await K.run(day);
      for (const x of r.v || []) { if ((await K.charge(x.reference)).user_id === u) { tries++; await K.failed(x.reference); } }
    }
    if (tries !== 4) bad.push(`${tries} tries before Free, the rule gives 4 (day 0, 1, 3, 7)`);
    return bad;
  } },
  { id: 'M2', title: 'runs missed on the billing date and 2 days after: still 4 tries before Free', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    let tries = 0, free = null;
    for (let k = 3; k <= 14; k++) {
      const day = addD(d, k); await K.today(day);
      const r = await K.run(day);
      for (const x of r.v || []) { if ((await K.charge(x.reference)).user_id === u) { tries++; await K.failed(x.reference); } }
      if (!free && (await K.row(u)).plan === 'free') free = k;
    }
    if (tries !== 4) bad.push(`${tries} tries before Free (on day ${free}), the rule gives 4`);
    return bad;
  } },
  { id: 'M3', net: true, title: 'a missed run day: the yearly 60-day notice and the 3-day removal notice still go', async run(K) {
    const bad = [], u = await K.user('home', { period: 'yearly' });
    await K.link(u, [{ id: P(1) }]);
    const r = await K.row(u);
    await K.sql(`update private.billing set plants_to_remove = '{${P(1)}}', remove_on = '${addD(r.next_billing_date, -30)}' where user_id = '${u}'`);
    for (const day of [addD(r.next_billing_date, -61), addD(r.next_billing_date, -59), addD(r.next_billing_date, -34), addD(r.next_billing_date, -32)]) { await K.today(day); await K.run(day); }
    const kinds = await K.sql(`select kind from public.email_queue where user_id = '${u}' and kind in ('bill_renewal_notice', 'bill_removal_soon')`);
    if (!kinds.includes('bill_renewal_notice')) bad.push('no renewal notice: its day (60 before) had no run');
    if (!kinds.includes('bill_removal_soon')) bad.push('no removal notice: its day (3 before) had no run');
    return bad;
  } },
  { id: 'W4', title: 'a refund event that comes before charge.success: the payment is not applied as kept money', async run(K) {
    const u = await K.user('home');
    const o = await K.open(u, 'family'); if (!o.ok) return ['open refused: ' + o.err];
    await K.db.t(`select to_jsonb(public.billing_charge_refund_event('${o.v.reference}', 'processed', null))`);
    const p = await K.paid(o.v.reference);
    const c = await K.charge(o.v.reference);
    return (p.v?.applied === false || c.refunded_at) ? [] : ['upgrade applied and the refund is lost: plan given, money back, nothing on record'];
  } },
  { id: 'K1', title: 'comped switched off to Free by hand: the next run leaves 1 plant collecting', async run(K) {
    const u = await K.user('family', { comped: true });
    await K.link(u, [{ id: P(1) }, { id: P(2) }, { id: P(3) }, { id: P(4) }]);
    // Decided 2026-10-31: the switch is billing_set_comped, which fits the plants.
    const s = await K.db.t(`select public.billing_set_comped('${u}', false)`); if (!s.ok) return ['switch refused: ' + s.err];
    await K.today('2027-03-11'); await K.run('2027-03-11');
    const bad = [], n = await K.active(u);
    if (n !== 1) bad.push(`${n} plants collect on Free after comped went off`);
    if (await K.paused(u, P(1))) bad.push('the first linked plant is not the one kept');
    const on = await K.db.t(`select public.billing_set_comped('${u}', true)`); if (!on.ok) return [...bad, 'switch on refused: ' + on.err];
    const r = await K.row(u);
    if (!r.comped || r.plan !== 'family') bad.push(`switched on: ${r.plan}, comped ${r.comped}`);
    if (!(await K.as(u, `select public.api_plant_start(${P(4)})`)).ok) bad.push('comped again, a 4th plant may not start');
    return bad;
  } },
  { id: 'R1', title: 'a refund Paystack refuses once: tried again, and a later success is dated', async run(K) {
    const bad = [], u = await K.user('home');
    const a = await K.open(u, 'family'), b = await K.open(u, 'family');
    await K.paid(a.v.reference);
    const p = await K.paid(b.v.reference); if (p.v?.applied !== false) return ['second payment was not marked for refund'];
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${b.v.reference}', 'paystack 500')) x`);
    const again = await K.paid(b.v.reference);
    if (again.v?.applied !== false && !again.v?.refund) bad.push('a replay after the refused refund does not ask for the refund again');
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${b.v.reference}', null)) x`);
    if (!(await K.charge(b.v.reference)).refunded_at) bad.push('a later successful refund is not dated (error no longer starts with "refund: ")');
    return bad;
  } },
  { id: 'R2', title: 'a retry declined after the user settled: the account stays active', async run(K) {
    const u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    await K.today(d); await K.run(d);
    const ren = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
    await K.failed(ren);
    const d1 = addD(d, 1); await K.today(d1); await K.run(d1);
    const retry = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal' and status = 'pending'`);
    const s = await K.db.t(`select public.billing_settle_open('${u}')`); await K.paid(s.v.reference);
    await K.failed(retry);                                    // the retry's decline comes back after the settle
    const r = await K.row(u);
    return r.state === 'active' ? [] : [`paid the settle, then past due again (since ${r.past_due_since}): Free on day 8 with the money kept`];
  } },
  { id: 'R5', title: 'an upgrade paid days after its card page opened costs the share left on the day it is paid', async run(K) {
    const u = await K.user('home');
    const r = await K.row(u);
    const open = addD(r.next_billing_date, -28); await K.today(open);
    const o = await K.open(u, 'family'); if (!o.ok) return ['open refused: ' + o.err];
    const pay = addD(r.next_billing_date, -3); await K.today(pay);
    const p = await K.paid(o.v.reference);
    const start = (await K.sql(`select public.billing_step('${r.next_billing_date}', 'monthly', ${r.billing_day}, -1)`))[0];
    const want = Number((await K.sql(`select public.billing_prorate(80, '${pay}', '${start}', '${r.next_billing_date}')`))[0]);
    if (p.v?.applied === false) return [];                    // refused and refunded: no overcharge
    return o.v.amount === want ? [] : [`R${o.v.amount} taken on ${pay}, the rule gives R${want} that day`];
  } },
  { id: 'Q1', title: 'a refund Paystack accepted and later failed no longer reads as refunded', async run(K) {
    const u = await K.user('home');
    const a = await K.open(u, 'family'), b = await K.open(u, 'family');
    await K.paid(a.v.reference); await K.paid(b.v.reference);
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${b.v.reference}', null)) x`);
    await K.db.t(`select to_jsonb(public.billing_charge_refund_event('${b.v.reference}', 'failed', 'bank rejected'))`);
    return (await K.charge(b.v.reference)).refunded_at ? ['refunded_at still set after refund.failed: the money reads as given back'] : [];
  } },
  { id: 'Q3', net: true, title: 'Free after day 8: a plant swapped in to collect is taken off the delete list', async run(K) {
    const u = await K.user('free');
    await K.link(u, [{ id: P(1) }, { id: P(2) }]);
    await K.sql(`update public.plant_users set paused = true where user_id = '${u}' and plant_id = ${P(2)};
      insert into private.billing (user_id, plan, plants_to_remove, remove_on) values ('${u}', 'free', '{${P(2)}}', '2027-04-09')
      on conflict (user_id) do update set plants_to_remove = '{${P(2)}}', remove_on = '2027-04-09'`);
    await K.as(u, `select public.api_plant_stop(${P(1)})`); await K.as(u, `select public.api_plant_start(${P(2)})`);
    await K.today('2027-04-09'); await K.run('2027-04-09');
    return (await K.active(u)) === 1 ? [] : [`${await K.active(u)} collecting after the removal date: the plant the user chose was deleted`];
  } },
  { id: 'E2', title: 'email changed after the card was saved: a paid renewal keeps card_email, so the next one still works', async run(K) {
    const u = await K.user('home');
    const before = (await K.row(u)).card_email;
    await K.sql(`update auth.users set email = 'moved-${u.slice(-4)}@sim.test' where id = '${u}'`);
    const d = (await K.row(u)).next_billing_date; await K.today(d); const r = await K.run(d);
    const x = (r.v || []).find((c) => c.email === before); if (!x) return ['renewal not sent with card_email'];
    await K.db.t(`select public.billing_charge_paid('${x.reference}', '{"authorization_code":"AUTH_1","reusable":true}'::jsonb, true, null)`);
    const after = (await K.row(u)).card_email;
    return after === before ? [] : [`card_email became ${after} after a paid renewal: the next renewal is refused by Paystack`];
  } },
  { id: 'X11', title: 'room bought while a plant stopped on purpose is older: the plant bought for starts', async run(K) {
    const u = await K.user('home');
    await K.link(u, [1, 2, 3, 4, 5, 6, 7].map((i) => ({ id: P(i) })));                   // 3-7 link stopped
    await K.as(u, `select public.api_plant_stop(${P(1)})`);                                 // 1 stopped on purpose
    await K.as(u, `select public.api_plant_start(${P(3)})`);                                // 3 fills the room
    const o = await K.open(u, 'family', null, null, [P(7)]); if (!o.ok) return ['open refused: ' + o.err];
    await K.paid(o.v.reference);                                                            // bought for P7
    return (await K.paused(u, P(7))) ? ['paid for P7, but it stays stopped'] : [];
  } },
  // ---- round 3 fixes (0130): delete, disputes, refunds ----
  { id: 'X13', title: 'Free to Family bought for one stopped plant: that plant starts, and the rest of the room fills too', async run(K) {
    // UI walk 2026-10-31: "plan is full" → Upgrade → Family named plant 2; only it started, the rest of the room stayed empty.
    const bad = [], u = await K.user('free');
    await K.link(u, [1, 2, 3, 4, 5, 6, 7].map((i) => ({ id: P(i) })));                  // 1 collects on Free
    const o = await K.open(u, 'family', 'monthly', null, [P(6)]); if (!o.ok) return ['refused: ' + o.err];
    const p = await K.paid(o.v.reference);
    if (!p.ok || p.v.applied === false) bad.push('paid but not applied: ' + JSON.stringify(p.v ?? p.err));
    if (await K.paused(u, P(6))) bad.push('the plant it was bought for stays stopped');
    if (await K.active(u) !== 5) bad.push(`${await K.active(u)} collect on Family, want 5`);
    return bad;
  } },
  { id: 'T1', title: 'day 8 to Free after the login of the oldest plant was removed: Free keeps a plant not booked for deletion', async run(K) {
    // code review 2026-10-31: Free kept the booked plant, so on remove_on every plant went.
    const bad = [], u = await K.user('family');
    await K.link(u, [1, 2, 3].map((i) => ({ id: P(i) })));
    const d = (await K.row(u)).next_billing_date;
    await K.today(d); await K.run(d);
    const ref = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal' limit 1`);
    await K.failed(ref);
    await K.db.t(`select to_jsonb(1) from (select public.billing_book_removal('${u}', ${P(1)})) x`);  // past due: Remove login of P1
    for (const n of [1, 3, 7, 8]) { const day = await K.db.json(`select to_jsonb(('${d}'::date + ${n})::text)`); await K.today(day); await K.run(day);
      const r = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal' and status = 'pending' limit 1`);
      if (r) await K.failed(r); }
    const row = await K.row(u);
    if (row.plan !== 'free') return ['did not fall to Free: ' + row.plan];
    const kept = await K.db.json(`select to_jsonb(coalesce(array_agg(plant_id), '{}')) from public.plant_users where user_id = '${u}' and not paused`);
    if (kept.some((id) => row.plants_to_remove.includes(id))) bad.push(`Free keeps ${kept}, booked for deletion with the rest: ${row.plants_to_remove}`);
    return bad;
  } },
  { id: 'X14', title: 'Home to Family, the newest stopped plant is booked for removal: it stays stopped and booked', async run(K) {
    const bad = [], u = await K.user('home');
    await K.link(u, [1, 2, 3, 4, 5, 6, 7, 8].map((i) => ({ id: P(i) })));              // 3-8 link stopped
    await K.db.t(`select to_jsonb(1) from (select public.billing_book_removal('${u}', ${P(8)})) x`);  // Remove login of P8
    const o = await K.open(u, 'family'); if (!o.ok) return ['refused: ' + o.err];
    await K.paid(o.v.reference);
    if (!(await K.paused(u, P(8)))) bad.push('the plant booked for removal started');
    if (!(await K.row(u)).plants_to_remove.includes(P(8))) bad.push('the removal booking went');
    if (await K.active(u) !== 5) bad.push(`${await K.active(u)} collect on Family, want 5`);
    return bad;
  } },
  { id: 'RF5', title: 'a refund Paystack accepts and then fails 7 times: hello@ is told', async run(K) {
    const bad = [], u = await K.user('home');
    const o = await K.open(u, 'family'); if (!o.ok) return ['open refused: ' + o.err];
    await K.paid(o.v.reference);
    const ref = await K.db.json(`select to_jsonb(public.billing_card_open('${u}')->>'reference')`);
    await K.paid(ref);                                                                // an R1 card check, refunded each time
    for (let i = 0; i < 7; i++) {
      await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${ref}', null)) x`);
      await K.db.t(`select to_jsonb(public.billing_charge_refund_event('${ref}', 'failed', 'Declined by issuer'))`);
    }
    const n = Number(await K.db.json(`select to_jsonb(count(*)) from public.email_queue where to_email = 'hello@princesolarhub.co.za' and key = 'bill_refund_stuck:${ref}'`));
    if (n !== 1) bad.push(`hello@ alerts: ${n}, want 1`);
    return bad;
  } },
  { id: 'RF6', title: 'Paystack refunds before the payment is reported: the user still gets the refund email', async run(K) {
    const u = await K.user('home');
    const o = await K.open(u, 'family'); if (!o.ok) return ['open refused: ' + o.err];
    await K.db.t(`select to_jsonb(public.billing_charge_refund_event('${o.v.reference}', 'processed', null))`);
    await K.paid(o.v.reference);
    const n = Number(await K.db.json(`select to_jsonb(count(*)) from public.email_queue where user_id = '${u}' and kind = 'bill_refund'`));
    return n === 1 ? [] : [`refund emails: ${n}, want 1`];
  } },
  { id: 'K2', title: 'on Free after day 8, Keep on a stopped plant booked for deletion is refused (only a swap brings it back)', async run(K) {
    // code review 2026-10-31: Keep took it off the delete list, so Free held stopped plants' history for good.
    const u = await K.user('family');
    await K.link(u, [1, 2].map((i) => ({ id: P(i) })));
    await K.sql(`select private.billing_to_free('${u}', '2027-03-10')`);                // day 8: P2 stopped, booked +30 days
    const r = await K.as(u, `select public.api_billing_keep(${P(2)})`);
    const row = await K.row(u);
    return row.plants_to_remove.includes(P(2)) ? [] : ['Free user kept a stopped plant off the delete list' + (r.ok ? '' : ' (' + r.err + ')')];
  } },
  { id: 'S3', title: 'a dispute lost on the billing date before the run: that period is still billed, the debt is tried after', async run(K) {
    // code review 2026-10-31 (case A): the debt row took the billing date, so the period's renewal was refunded as not due.
    const bad = [], u = await K.user('home');
    const d0 = (await K.row(u)).next_billing_date;
    await K.today(d0); await K.run(d0);
    const oct = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
    await K.paid(oct);
    const d1 = (await K.row(u)).next_billing_date;                                     // next billing date
    await K.today(d1);
    await K.db.t(`select to_jsonb(public.billing_charge_disputed('${oct}', 'lost', true, 9900))`);  // lost before the run
    await K.run(d1);
    const nov = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal' and due_on = '${d1}' and error is null order by created_at limit 1`);
    if (!nov) return ['no renewal for the billing date'];
    const p = await K.paid(nov);
    if (p.v?.applied === false) bad.push('the period renewal was refunded: ' + (await K.charge(nov)).error);
    for (let k = 1; k <= 2; k++) { const x = addD(d1, k); await K.today(x); await K.run(x); }
    const r = await K.row(u);
    if (r.state !== 'past_due') bad.push(`the lost dispute was never owed: ${r.state}`);
    return bad;
  } },
  { id: 'S4', title: 'a dispute lost while the renewal is still open at Paystack: the renewal applies when paid, the debt after', async run(K) {
    const bad = [], u = await K.user('home');
    const d0 = (await K.row(u)).next_billing_date;
    await K.today(d0); await K.run(d0);
    const oct = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
    await K.paid(oct);
    const d1 = (await K.row(u)).next_billing_date;
    await K.today(d1); await K.run(d1);                                                // November handed out, no answer
    const nov = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal' and due_on = '${d1}'`);
    const x = addD(d1, 1); await K.today(x);
    await K.db.t(`select to_jsonb(public.billing_charge_disputed('${oct}', 'lost', true, 9900))`);
    const p = await K.paid(nov);
    if (p.v?.applied === false) bad.push('the open renewal was refunded: ' + (await K.charge(nov)).error);
    const y = addD(d1, 2); await K.today(y); await K.run(y);
    if ((await K.row(u)).state !== 'past_due') bad.push('the lost dispute was never owed');
    return bad;
  } },
  { id: 'S5', title: 'a dispute lost while already past due: owed once the failed renewal is settled', async run(K) {
    const bad = [], u = await K.user('home');
    const d0 = (await K.row(u)).next_billing_date;
    await K.today(d0); await K.run(d0);
    const oct = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
    await K.paid(oct);
    const d1 = (await K.row(u)).next_billing_date;
    await K.today(d1); await K.run(d1);
    const nov = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal' and due_on = '${d1}'`);
    await K.failed(nov);                                                               // past due for November
    const x = addD(d1, 2); await K.today(x);
    await K.db.t(`select to_jsonb(public.billing_charge_disputed('${oct}', 'lost', true, 9900))`);
    const s = await K.db.t(`select public.billing_settle_open('${u}')`); if (!s.ok) return ['settle refused: ' + s.err];
    await K.paid(s.v.reference);                                                       // November settled
    const y = addD(d1, 3); await K.today(y); await K.run(y);
    if ((await K.row(u)).state !== 'past_due') bad.push('the dispute lost while past due was never owed');
    return bad;
  } },
  { id: 'A7', title: 'a renewal open at Paystack for 3 days, failed on the 3rd: that day still gets its retry', async run(K) {
    // code review 2026-10-31: the expiry moved created_on to that day first, so the day-3 slot counted as tried.
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    const tries = [];
    for (let k = 0; k <= 9; k++) {
      const x = addD(d, k); await K.today(x);
      const run = await K.run(x);
      for (const t of run.v || []) if ((await K.charge(t.reference)).user_id === u) { tries.push(k); if (k >= 3) await K.failed(t.reference); }
    }
    const handed = [...new Set(tries)];
    if (!handed.includes(3)) bad.push(`handed out on days ${handed.join(', ')}: no try on day 3`);
    return bad;
  } },
  { id: 'A8', title: 'a renewal handed out but never started (the call ran out of time): no try is counted for it', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    await K.today(d);
    const run0 = await K.run(d);
    const mine = [];
    for (const t of run0.v || []) if ((await K.charge(t.reference)).user_id === u) mine.push(t.reference);
    await K.sql(`select public.billing_run_release(array['${mine.join("','")}'])`);    // not reached: back for the next call
    const fails = [];
    for (let k = 1; k <= 12; k++) {
      const x = addD(d, k); await K.today(x);
      const run = await K.run(x);
      for (const t of run.v || []) if ((await K.charge(t.reference)).user_id === u) { fails.push(k); await K.failed(t.reference); }
      if ((await K.row(u)).plan === 'free') break;
    }
    if (fails.length !== 4) bad.push(`${fails.length} real tries before Free (days ${fails.join(', ')}), want 4`);
    return bad;
  } },
  { id: 'RF7', title: 'a refund Paystack fails after the account was deleted: hello@ is told', async run(K) {
    const u = await K.user('home');
    const ref = await K.db.json(`select to_jsonb(public.billing_card_open('${u}')->>'reference')`);
    await K.paid(ref);
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${ref}', null)) x`);   // asked
    await K.as(u, `select public.api_billing_change('free', null)`);                                  // cancel booked
    const del = await K.as(u, `select public.api_account_delete()`);                                  // allowed: the refund is asked
    if (!del.ok) return ['delete refused: ' + del.err];
    await K.db.t(`select to_jsonb(public.billing_charge_refund_event('${ref}', 'failed', 'Declined by issuer'))`);
    const n = Number(await K.db.json(`select to_jsonb(count(*)) from public.email_queue where to_email = 'hello@princesolarhub.co.za' and data->>'key' = '${ref}'`));
    return n === 1 ? [] : [`hello@ alerts: ${n}, want 1`];
  } },
  { id: 'D6', title: 'a refund refused 7 times (hello@ told) no longer blocks account delete for good', async run(K) {
    const u = await K.user('home');
    const ref = await K.db.json(`select to_jsonb(public.billing_card_open('${u}')->>'reference')`);
    await K.paid(ref);
    for (let i = 0; i < 7; i++) await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${ref}', 'refused')) x`);
    await K.as(u, `select public.api_billing_change('free', null)`);
    const r = await K.as(u, `select public.api_account_delete()`);
    return r.ok ? [] : ['delete still refused: ' + r.err];
  } },
  { id: 'W6', title: 'a card check whose refund failed once, then reversed: verify reads it as the card change, not as a refund', async run(K) {
    const u = await K.user('home');
    const ref = await K.db.json(`select to_jsonb(public.billing_card_open('${u}')->>'reference')`);
    await K.paid(ref);
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${ref}', 'refused')) x`);
    const r = await K.db.t(`select public.billing_charge_failed('${ref}', 'reversed')`);
    return r.v?.applied === false ? ['a card check reads as "not applied": the app would say the plan changed'] : [];
  } },
  { id: 'RF8', title: 'the hello@ alert for a stuck refund goes once, even after its queue row is gone', async run(K) {
    const u = await K.user('home');
    const ref = await K.db.json(`select to_jsonb(public.billing_card_open('${u}')->>'reference')`);
    await K.paid(ref);
    for (let i = 0; i < 7; i++) await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${ref}', 'refused')) x`);
    await K.sql(`delete from public.email_queue where key = 'bill_refund_stuck:${ref}'`);              // sent and cleared (email_done)
    await K.db.t(`select to_jsonb(public.billing_charge_refund_event('${ref}', 'failed', 'again'))`);
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${ref}', 'refused')) x`);
    const n = Number(await K.db.json(`select to_jsonb(count(*)) from public.email_queue where key = 'bill_refund_stuck:${ref}'`));
    return n === 0 ? [] : [`${n} more alerts for one stuck refund`];
  } },
  { id: 'T2', title: 'Free after day 8, then a paid start: plants the new plan starts are kept, the rest are still deleted on their date', async run(K) {
    // Rule (Brynne, 2026-11-01): paying again does not cancel the 30-day deletion of plants past the new plan's room.
    const bad = [], u = await K.user('family');
    await K.link(u, [1, 2, 3, 4, 5, 6].map((i) => ({ id: P(i) })));
    await K.sql(`select private.billing_to_free('${u}', '2027-03-10')`);                   // P2-P6 booked for 2027-04-09
    const o = await K.open(u, 'family', 'monthly'); if (!o.ok) return ['start refused: ' + o.err];
    await K.paid(o.v.reference);                                                          // Family: P1-P5 collect
    const r = await K.row(u);
    if (!r.plants_to_remove.includes(P(6))) bad.push('the plant past the room is no longer booked for deletion');
    if ([2, 3, 4, 5].some((i) => r.plants_to_remove.includes(P(i)))) bad.push('a plant the plan started is still booked');
    await K.today('2027-04-09'); await K.run('2027-04-09');
    const left = await K.db.json(`select to_jsonb(coalesce(array_agg(plant_id order by plant_id), '{}')) from public.plant_users where user_id = '${u}'`);
    if (JSON.stringify(left) !== JSON.stringify([1, 2, 3, 4, 5].map(P))) bad.push(`left after the date: ${left}, want P1-P5`);
    return bad;
  } },
  { id: 'T3', title: 'after the paid start, a booked plant swapped in on the paid plan is kept; the one swapped out stays', async run(K) {
    const bad = [], u = await K.user('family');
    await K.link(u, [1, 2, 3, 4].map((i) => ({ id: P(i) })));
    await K.sql(`select private.billing_to_free('${u}', '2027-03-10')`);
    const o = await K.open(u, 'family', 'monthly'); if (!o.ok) return ['start refused: ' + o.err];
    await K.paid(o.v.reference);
    await K.as(u, `select public.api_plant_stop(${P(3)})`);
    const st = await K.as(u, `select public.api_plant_start(${P(4)})`);                   // swap P4 in
    if (!st.ok) return ['start refused: ' + st.err];
    await K.today('2027-04-09'); await K.run('2027-04-09');
    const left = Number(await K.db.json(`select to_jsonb(count(*)) from public.plant_users where user_id = '${u}'`));
    if (left !== 4) bad.push(`${4 - left} plants deleted: the swapped-in plant (collecting) or the stopped one went`);
    return bad;
  } },
  { id: 'K3', title: 'on the paid plan after the start, Keep on a stopped plant Free booked is refused (only a swap keeps it)', async run(K) {
    const u = await K.user('family');
    await K.link(u, [1, 2, 3, 4, 5, 6].map((i) => ({ id: P(i) })));
    await K.sql(`select private.billing_to_free('${u}', '2027-03-10')`);
    const o = await K.open(u, 'family', 'monthly'); if (!o.ok) return ['start refused: ' + o.err];
    await K.paid(o.v.reference);
    await K.as(u, `select public.api_billing_keep(${P(6)})`);
    return (await K.row(u)).plants_to_remove.includes(P(6)) ? [] : ['Keep took a plant the plan does not run off the delete list'];
  } },
  { id: 'C1', title: 'a card page left unpaid for 2 days is closed, not left open for ever', async run(K) {
    const u = await K.user('home');
    const o = await K.open(u, 'family'); if (!o.ok) return ['open refused: ' + o.err];
    const d = addD('2027-03-10', 3); await K.today(d);
    await K.sql(`update private.billing_charges set created_at = created_at - interval '3 days' where reference = '${o.v.reference}'`);  // 3 days pass
    await K.run(d);
    const c = await K.charge(o.v.reference);
    return c.status === 'pending' ? ['card page charge still open after 3 days'] : [];
  } },
  { id: 'Q4', title: 'Billing\'s "Pay by" date is the day the run moves the account to Free, also after a missed run day', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    const failMine = async (run) => { for (const t of run.v || []) if ((await K.charge(t.reference)).user_id === u) await K.failed(t.reference); };
    let said = null, freeDay = null;
    for (const k of [0, 1, 7, 8, 9, 10]) {                                              // day 3's run is missed
      const x = addD(d, k); await K.today(x); await failMine(await K.run(x));
      const st = await K.as(u, `select public.api_billing_status()`);
      if (k === 7) said = st.v?.freeOn;
      if (!freeDay && (await K.row(u)).plan === 'free') freeDay = x;
    }
    if (said !== freeDay) bad.push(`Billing said Pay by ${said}, the account moved to Free on ${freeDay}`);
    return bad;
  } },
  { id: 'D4', title: 'account delete after a booked cancel goes through (the plan runs to its date, no refund)', async run(K) {
    const u = await K.user('home');
    const c = await K.as(u, `select public.api_billing_change('free', null)`); if (!c.ok) return ['cancel refused: ' + c.err];
    const d = await K.as(u, `select public.api_account_delete()`);
    return d.ok ? [] : ['delete refused with the cancel booked: ' + d.err];
  } },
  { id: 'S1', title: 'a lost dispute on a paid renewal: past due from that day, tries on day 1, 3, 7, Free on day 8', async run(K) {
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    await K.today(d); await K.run(d);
    const ren = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'renewal'`);
    await K.paid(ren);
    const lost = addD(d, 5); await K.today(lost);
    const x = await K.db.t(`select to_jsonb(public.billing_charge_disputed('${ren}', 'lost', true, 9900))`);
    if (!x.ok || x.v !== true) return ['dispute not taken: ' + (x.err || x.v)];
    const c = await K.charge(ren);
    if (!c.dispute_lost || c.refunded_cents !== 9900) bad.push(`dispute not recorded: ${JSON.stringify({ d: c.dispute, lost: c.dispute_lost, cents: c.refunded_cents })}`);
    let r = await K.row(u);
    if (r.state !== 'past_due' || r.past_due_since !== lost) bad.push(`after the dispute: ${r.state} since ${r.past_due_since}`);
    const days = [];
    for (let k = 1; k <= 8; k++) {
      const day = addD(lost, k); await K.today(day);
      const run = await K.run(day);
      for (const t of run.v || []) if ((await K.charge(t.reference)).user_id === u) { days.push(k); await K.failed(t.reference); }
    }
    if (JSON.stringify(days) !== '[1,3,7]') bad.push(`tried on days ${days.join(', ')}, want 1, 3, 7`);
    if ((await K.row(u)).plan !== 'free') bad.push('not on Free on day 8');
    const again = await K.db.t(`select to_jsonb(public.billing_charge_disputed('${ren}', 'lost', true, 9900))`);
    if (Number((await K.sql(`select count(*) from private.billing_charges where user_id = '${u}' and error like 'dispute lost%'`))[0]) !== 1) bad.push('a replayed dispute counted twice');
    return again.ok ? bad : [...bad, again.err];
  } },
  { id: 'S2', title: 'a dispute still open changes nothing but the record; settling a lost one makes the account active', async run(K) {
    const bad = [], u = await K.user('home');
    const start = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'start'`);
    await K.db.t(`select to_jsonb(public.billing_charge_disputed('${start}', 'awaiting-merchant-feedback', false, null))`);
    if ((await K.row(u)).state !== 'active') bad.push('open dispute made the account past due');
    if ((await K.charge(start)).dispute !== 'awaiting-merchant-feedback') bad.push('open dispute not written');
    await K.db.t(`select to_jsonb(public.billing_charge_disputed('${start}', 'lost', true, null))`);
    const s = await K.db.t(`select public.billing_settle_open('${u}')`); if (!s.ok) return [...bad, 'settle refused: ' + s.err];
    if (s.v.amount !== 99) bad.push(`settle asks R${s.v.amount}, the payment taken back was R99`);
    const p = await K.paid(s.v.reference);
    if (p.v?.applied === false || (await K.row(u)).state !== 'active') bad.push('settle after a lost dispute not applied');
    return bad;
  } },
  { id: 'RF1', title: 'a payment we refund sends the user a refund email; the R1 card check does not', async run(K) {
    const bad = [], u = await K.user('home');
    const a = await K.open(u, 'family'), b = await K.open(u, 'family');
    await K.paid(a.v.reference); await K.paid(b.v.reference);
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${b.v.reference}', null)) x`);
    const card = await K.db.t(`select public.billing_card_open('${u}')`);
    await K.db.t(`select public.billing_charge_paid('${card.v.reference}', '{"authorization_code":"AUTH_NEW","reusable":true}'::jsonb, true, null)`);
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${card.v.reference}', null)) x`);
    const mails = await K.db.json(`select coalesce(jsonb_agg(data), '[]') from public.email_queue where user_id = '${u}' and kind = 'bill_refund'`);
    if (mails.length !== 1) bad.push(`${mails.length} refund emails, want 1`);
    else if (mails[0].amount !== b.v.amount) bad.push(`refund email says R${mails[0].amount}, R${b.v.amount} went back`);
    return bad;
  } },
  { id: 'RF2', title: 'a refused refund is listed for the daily run until one is taken; an applied payment never is', async run(K) {
    const bad = [], u = await K.user('home');
    const a = await K.open(u, 'family'), b = await K.open(u, 'family');
    await K.paid(a.v.reference); await K.paid(b.v.reference);
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${b.v.reference}', 'paystack 500')) x`);
    const due = async () => (await K.sql(`select public.billing_refunds_due()`));
    await K.sql(`update private.billing_charges set settled_at = now() - interval '2 hours' where user_id = '${u}'`);
    if ((await due()).includes(b.v.reference)) bad.push('asked again within the day of a refusal');
    await K.sql(`update private.billing_charges set refund_tried_at = now() - interval '1 day' where user_id = '${u}'`);
    let list = await due();
    if (!list.includes(b.v.reference)) bad.push('refused refund not listed for the run');
    if (list.includes(a.v.reference)) bad.push('an applied payment is listed for refund');
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${b.v.reference}', null)) x`);
    list = await due();
    if (list.includes(b.v.reference)) bad.push('listed again after Paystack took the refund');
    const st = await K.as(u, `select public.api_billing_status()`);
    // 0184: the refunded payment stays listed, with a status
    const pay = st.v.payments || [];
    if (pay.length !== 3) bad.push(`${pay.length} payments listed, want the start, the upgrade and the refunded one`);
    if (pay.filter(p => p.status === 'refunded').length !== 1) bad.push(`statuses ${pay.map(p => p.status).join(', ')}, want one refunded`);
    return bad;
  } },
  { id: 'RF4', title: 'Paystack\'s refund event before our refund call: the refund email still goes, once', async run(K) {
    const u = await K.user('home');
    const a = await K.open(u, 'family'), b = await K.open(u, 'family');
    await K.paid(a.v.reference); await K.paid(b.v.reference);
    await K.db.t(`select to_jsonb(public.billing_charge_refund_event('${b.v.reference}', 'pending', null, null, null))`);
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${b.v.reference}', null)) x`);
    const n = Number((await K.sql(`select count(*) from public.email_queue where user_id = '${u}' and kind = 'bill_refund'`))[0]);
    return n === 1 ? [] : [`${n} refund emails, want 1`];
  } },
  { id: 'D5', title: 'account delete with a cancel booked but a refund not yet gone back is refused', async run(K) {
    const u = await K.user('home');
    const a = await K.open(u, 'family'), b = await K.open(u, 'family');
    await K.paid(a.v.reference); await K.paid(b.v.reference);            // b: marked for refund
    await K.db.t(`select to_jsonb(1) from (select public.billing_charge_refunded('${b.v.reference}', 'paystack 500')) x`);
    await K.sql(`update private.billing set next_plan = 'free' where user_id = '${u}';
                 update private.billing_charges set created_at = now() - interval '2 days' where user_id = '${u}'`);
    const d = await K.as(u, `select public.api_account_delete()`);
    return d.ok ? ['deleted with a refund still owed: the charge row the refund needs is gone'] : [];
  } },
  { id: 'N1', net: true, title: 'an account set past due by hand, with no failed renewal: the daily run still runs for everyone, no retry, Free on day 8 (SOLAR-437)', async run(K) {
    // Found by sim.mjs --seed 372 while abuse.mjs (G5a, G7e) had such an account committed: the retry
    // read the failed renewal, found none, and inserted a charge with no plan. The whole run raised.
    const bad = [], h = await K.user('home'), u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    await K.sql(`update private.billing set state = 'past_due', past_due_since = '${d}' where user_id = '${h}'`);
    await K.sql(`update private.billing set next_billing_date = '${d}', billing_day = ${+d.slice(8, 10)} where user_id = '${u}'`);
    await K.today(d);
    const r = await K.run(d);
    if (!r.ok) return [`billing_run raised: ${r.err}`];
    const mine = [];
    for (const t of r.v || []) mine.push((await K.charge(t.reference)).user_id);
    if (!mine.includes(u)) bad.push('the other account\'s renewal was not handed out');
    for (const k of [1, 3, 7]) {
      await K.today(addD(d, k)); const x = await K.run(addD(d, k));
      if (!x.ok) { bad.push(`day ${k}: billing_run raised: ${x.err}`); break; }
      for (const t of x.v || []) if ((await K.charge(t.reference)).user_id === h) bad.push(`day ${k}: a retry with nothing to retry`);
    }
    await K.today(addD(d, 8)); await K.run(addD(d, 8));
    if ((await K.row(h)).plan !== 'free') bad.push('still on Home after day 8');
    return bad;
  } },
  { id: 'A6', title: 'a renewal Paystack keeps open 3 days, then failed: a real try on day 3 (no card was charged that day), day 7, Free on day 8', async run(K) {
    // changed by 0132 (Brynne, 2026-10-31): the expiry day no longer counts as the day-3 try.
    const bad = [], u = await K.user('home');
    const d = (await K.row(u)).next_billing_date;
    const days = [];
    for (let k = 0; k <= 8; k++) {
      const x = addD(d, k); await K.today(x); const r = await K.run(x);
      for (const t of r.v || []) {
        const c = await K.charge(t.reference);
        if (c.user_id !== u) continue;
        if (k >= 3) { days.push(k); await K.failed(t.reference); }      // days 0-2: no answer, left open
      }
    }
    if (JSON.stringify(days) !== '[3,7]') bad.push(`new tries on days ${days.join(', ')}, want 3 and 7`);
    if ((await K.row(u)).plan !== 'free') bad.push('not on Free on day 8');
    return bad;
  } },
  { id: 'RF3', title: 'a hand refund of R40 on a renewal: R40 recorded, listed as partly refunded, the plan stays', async run(K) {
    const bad = [], u = await K.user('home');
    const start = await K.db.json(`select to_jsonb(reference) from private.billing_charges where user_id = '${u}' and kind = 'start'`);
    await K.db.t(`select to_jsonb(public.billing_charge_refund_event('${start}', 'processed', null, 4000, 'rf_1'))`);
    await K.db.t(`select to_jsonb(public.billing_charge_refund_event('${start}', 'processed', null, 4000, 'rf_1'))`);
    const c = await K.charge(start);
    if (c.refunded_cents !== 4000 || c.refund_status !== 'done') bad.push(`recorded ${c.refunded_cents} cents, ${c.refund_status}`);
    const st = await K.as(u, `select public.api_billing_status()`);
    // 0184: the payment stays listed, with a status
    const pay = st.v.payments || [];
    if (pay.length !== 1 || pay[0].status !== 'part_refunded') bad.push(`payments ${JSON.stringify(pay.map(p => p.status))}, want one part_refunded`);
    if (st.v.plan !== 'home' || st.v.state !== 'active') bad.push(`plan became ${st.v.plan} ${st.v.state}`);
    return bad;
  } },
  { id: 'PF1', title: 'a failed payment: no cancel, smaller plan or switch until it is paid; a change booked before it can still be undone (SOLAR-497)', async run(K) {
    const bad = [], u = await K.user('family');
    const booked = await K.as(u, `select public.api_billing_change('home', null)`);
    if (!booked.ok) return ['downgrade refused while active: ' + booked.err];
    const d = (await K.row(u)).next_billing_date;
    await K.sql(`update private.billing set state = 'past_due', past_due_since = '${d}' where user_id = '${u}';
                 delete from public.email_queue where user_id = '${u}'`);
    for (const [what, q] of [['cancel', `select public.api_billing_change('free', null)`],
                             ['another plan', `select public.api_billing_change('home', 'yearly')`],
                             ['a switch to yearly', `select public.api_billing_change('family', 'yearly')`]]) {
      const r = await K.as(u, q);
      if (r.ok) bad.push(`${what} allowed while the payment is failed`);
      else if (!/pay the failed payment first/.test(r.err)) bad.push(`${what} refused for another reason: ${r.err}`);
    }
    if ((await K.row(u)).next_plan !== 'home') bad.push('the downgrade booked before the failure was lost');
    await K.held(u, 2);
    const x = await K.extras(u, 1);
    if (x.ok) bad.push('a drop of extra plants allowed while the payment is failed');
    await K.held(u, 0);
    if (Number((await K.sql(`select count(*) from public.email_queue where user_id = '${u}' and kind = 'bill_change'`))[0])) bad.push('a refused change was emailed');
    const undo = await K.as(u, `select public.api_billing_change('family', 'monthly')`);
    if (!undo.ok) bad.push('Keep Family refused: ' + undo.err);
    const b = await K.row(u);
    if (b.next_plan !== null) bad.push('Keep Family left the downgrade booked');
    if (b.state !== 'past_due') bad.push(`state became ${b.state}`);
    return bad;
  } },
];
const addD = (d, k) => new Date(Date.parse(d) + k * 864e5).toISOString().slice(0, 10);
