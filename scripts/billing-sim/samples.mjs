#!/usr/bin/env node
// UI sample users (SOLAR-264): 13 users in clearly different billing states, left in the local database
// at real today, so the Billing screen can be looked at. Writes ui-samples.json.
//   node scripts/billing-sim/samples.mjs           build (replaces earlier samples)
//   node scripts/billing-sim/samples.mjs --remove  delete them
// Local database only. No plant is started through billing_resume, so nothing calls plant_bootstrap_kick
// (which posts to the hosted functions). No tokens or links are made here.
import { writeFileSync } from 'node:fs';
import { Db, SESSION_SQL } from './db.mjs';

const db = new Db();
const OUT = new URL('./ui-samples.json', import.meta.url);
const longDay = (d) => new Date(d + 'T00:00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });
const billDay = (d) => new Date(d + 'T00:00:00').toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
const rand = (n) => 'R' + Number(n).toLocaleString('en-US');
const perUnit = (p) => (p === 'yearly' ? 'a year' : 'a month');
const NAME = { free: 'Free', home: 'Home', family: 'Family' };
const uuid = (n) => `00000000-0000-4000-8000-0000000051${String(n).padStart(2, '0')}`;
const email = (n) => `ui-sample-${n}@sim.test`;

async function remove() {
  await db.exec(`
delete from public.email_queue where user_id::text like '00000000-0000-4000-8000-0000000051__';
delete from private.free_week_logins where sunsynk_username like 'ui-sample-%@login.test';
delete from private.inverters where sn like 'UISAMPLE-%';
delete from public.plant_config where plant_id between 8100000 and 8199999;
delete from auth.users where email like 'ui-sample-%@sim.test';`);
}

// each plant: [inverters, state] state 'on' | 'off' (stopped)
const SAMPLES = [
  { n: 1, kind: 'Free', plan: 'free', plants: [[1, 'on']] },
  { n: 2, kind: 'Home monthly', plan: 'home', period: 'monthly', plants: [[1, 'on']] },
  { n: 3, kind: 'Home yearly', plan: 'home', period: 'yearly', plants: [[2, 'on']] },
  { n: 4, kind: 'Family monthly, 3 plants', plan: 'family', period: 'monthly', plants: [[1, 'on'], [1, 'on'], [2, 'on']] },
  { n: 5, kind: 'Family monthly, 2 extra plants (1 and 2 inverters)', plan: 'family', period: 'monthly', plants: [[1, 'on'], [1, 'on'], [2, 'on'], [1, 'on'], [2, 'on']], extras: 2 },
  { n: 6, kind: 'Family monthly, downgrade to Home booked', plan: 'family', period: 'monthly', plants: [[1, 'on'], [1, 'off']], book: ['home', null] },
  { n: 7, kind: 'Home monthly, cancel booked', plan: 'home', period: 'monthly', plants: [[1, 'on']], book: ['free', null] },
  { n: 8, kind: 'Family monthly, payment failed', plan: 'family', period: 'monthly', plants: [[1, 'on'], [2, 'on']], pastDue: true },
  { n: 9, kind: 'Family monthly, one plant booked for removal', plan: 'family', period: 'monthly', plants: [[1, 'on'], [1, 'on'], [2, 'on']], remove: 2 },
  { n: 10, kind: 'Family monthly, one plant stopped', plan: 'family', period: 'monthly', plants: [[1, 'on'], [1, 'on'], [2, 'off']] },
  { n: 11, kind: 'Family yearly, 1 extra plant of 2 inverters', plan: 'family', period: 'yearly', plants: [[1, 'on'], [1, 'on'], [1, 'on'], [2, 'on']], extras: 1 },
  { n: 12, kind: 'Comped Family', plan: 'family', comped: true, plants: [[1, 'on'], [2, 'on'], [1, 'on'], [3, 'on']] },
  { n: 13, kind: 'Home monthly, switch to yearly booked', plan: 'home', period: 'monthly', plants: [[1, 'on']], book: ['home', 'yearly'] },
];

async function must(sql) { const r = await db.t(sql); if (!r.ok) throw new Error(`${r.err}\n--- ${sql}`); return r.v; }

async function build() {
  const today = (await db.exec(`select (now() at time zone 'Africa/Johannesburg')::date`))[0];
  await remove();
  await db.exec('begin;');
  try {
    for (const S of SAMPLES) {
      const id = uuid(S.n), em = email(S.n), login = `ui-sample-${S.n}@login.test`;
      // Token columns '' as GoTrue writes them: NULL breaks generate_link for these users.
      await db.exec(`insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                                             confirmation_token, recovery_token, email_change_token_new, email_change)
        values ('${id}', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '${em}', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
        insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
        values ('${id}', '${id}', jsonb_build_object('sub', '${id}', 'email', '${em}', 'email_verified', true), 'email', now(), now(), now());`);
      const acc = (await db.exec(`insert into private.sunsynk_accounts (user_id, sunsynk_username) values ('${id}', '${login}') returning id`))[0];
      // plants are added after the payment, already collecting or stopped, so no plant is "resumed"
      const addPlants = async (from, to) => {
        for (let k = from; k < to; k++) {
          const pid = 8100000 + S.n * 10 + k, [inv, st] = S.plants[k];
          await db.exec(`insert into public.plant_users (plant_id, user_id, account_id, plant_name, linked_at, paused)
            values (${pid}, '${id}', '${acc}', 'Sample ${S.n} plant ${k + 1}', timestamptz '2026-10-01 00:00:00+00' + interval '${k + 1} minutes', ${st === 'off'});`);
          for (let j = 0; j < inv; j++) await db.exec(`insert into private.inverters (sn, plant_id, account_id) values ('UISAMPLE-${pid}-${j}', ${pid}, '${acc}');`);
        }
      };
      if (S.comped) {
        await db.exec(`insert into private.billing (user_id, plan, comped) values ('${id}', 'family', true);`);
        await addPlants(0, S.plants.length);
      } else if (S.plan === 'free') {
        await addPlants(0, S.plants.length);
        await db.exec(`select public.billing_free_week_start('${id}', '${login}');`);
      } else {
        // pay first, with no plants linked yet: the payment then has nothing to resume (a resume would call
        // plant_bootstrap_kick, which posts to the hosted functions). The plants appear afterwards.
        const q = await must(`select public.billing_charge_open('${id}', '${S.plan}', '${S.period}', ${S.extras ?? 'null'})`);
        await must(`select public.billing_charge_paid('${q.reference}', '{"authorization_code":"AUTH_UI${S.n}","reusable":true,"last4":"${4000 + S.n}","card_type":"visa ","exp_month":"12","exp_year":"2031"}'::jsonb, true, null)`);
        await addPlants(0, S.plants.length);
        if (S.book) await must(`select to_jsonb(1) from (select public.billing_book_change('${id}', '${S.book[0]}', ${S.book[1] ? `'${S.book[1]}'` : 'null'})) x`);
        if (S.remove !== undefined) await must(`select to_jsonb(1) from (select public.billing_book_removal('${id}', ${8100000 + S.n * 10 + S.remove})) x`);
        if (S.pastDue) {
          const b = (await db.json(`select to_jsonb(b) from private.billing b where user_id = '${id}'`));
          const ref = `psh_uisample${S.n}`;
          await db.exec(`insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on)
            values ('${ref}', '${id}', 'renewal', '${S.plan}', '${S.period}', public.billing_amount_due('${id}'), '${today}', '${today}');`);
          await must(`select public.billing_charge_failed('${ref}', 'declined')`);
        }
      }
    }
    await db.exec(`delete from public.email_queue where user_id::text like '00000000-0000-4000-8000-0000000051__';`);
    await db.exec('commit;');
  } catch (e) { await db.run('rollback;'); throw e; }

  // read each one back and build what the Billing screen shows
  const manifest = [];
  for (const S of SAMPLES) {
    const id = uuid(S.n);
    const s = await db.json(`select pg_temp.snap('${id}')`);
    const g = s.st;
    const act = s.plants.filter((p) => !p.paused).length;
    const names = await db.json(`select coalesce(jsonb_agg(jsonb_build_object('id', plant_id, 'name', plant_name, 'paused', paused) order by linked_at, plant_id), '[]') from public.plant_users where user_id = '${id}'`);
    const stopped = names.filter((p) => p.paused).map((p) => p.name);
    const paid = g.plan !== 'free' && !g.comped;
    const ending = paid && g.nextPlan === 'free';
    const state = g.state === 'past_due' ? 'Payment failed' : ending ? 'Ends ' + billDay(g.nextDate) : 'Active';
    const line = g.comped ? 'Free of charge. Every plant, full history.'
      : paid ? `${rand(g.price)} ${perUnit(g.period)} for ${act === 1 ? '1 plant' : act + ' plants'}. ${ending ? 'Ends' : 'Renews'} on ${longDay(g.nextDate)}.`
      : '1 plant and the last 24 hours. No card needed.';
    const extraInv = g.comped ? 0 : g.extraPlants; // comped plants cost nothing
    const prices = g.prices;
    const breakdown = paid && g.plan === 'family' && extraInv > 0
      ? `Family ${rand(prices[g.period].family)} + ${extraInv === 1 ? '1 extra plant' : extraInv + ' extra plants'} ${rand(extraInv * prices[g.period].extra)}` : null;
    const booked = !paid ? null : g.nextPlan === 'free' ? `Ends on ${billDay(g.nextDate)}, then you’re on Free.`
      : g.nextPlan ? `Moves to ${NAME[g.nextPlan]} on ${billDay(g.nextDate)}.` : g.nextPeriod ? `Switches to ${g.nextPeriod} on ${billDay(g.nextDate)}.` : null;
    const removal = g.removePlants.map((p) => p.name);
    // what each sample must show, written by hand from the kind
    const want = { plan: S.plan, period: S.period ?? null, collecting: S.plants.filter((p) => p[1] === 'on').length - (S.remove !== undefined ? 0 : 0), extraInv: S.extras ?? 0 };
    const bad = [];
    if (g.plan !== want.plan) bad.push('plan');
    if (act !== want.collecting) bad.push(`collecting ${act} != ${want.collecting}`);
    if (extraInv !== want.extraInv) bad.push(`extra ${extraInv} != ${want.extraInv}`);
    if (S.pastDue && g.state !== 'past_due') bad.push('state');
    if (bad.length) throw new Error(`sample ${S.n} wrong: ${bad.join(', ')} ${JSON.stringify(g)}`);
    manifest.push({
      email: email(S.n), kind: S.kind,
      billingScreen: {
        planName: NAME[g.plan], comped: g.comped, stateWord: state, priceLine: line,
        price: g.price, nextAmount: g.nextAmount, period: g.period, billingState: g.state,
        plantsCollecting: act, plantsTotal: names.length, extraInverters: extraInv, extraBreakdown: breakdown,
        nextDate: g.nextDate, nextDateLong: g.nextDate ? longDay(g.nextDate) : null,
        bookedLine: booked, stoppedPlants: stopped, plantsBookedForRemoval: removal, removeOn: g.removeOn,
        paymentFailedBanner: g.state === 'past_due', savedCardLast4: s.card,
      },
    });
  }
  writeFileSync(OUT, JSON.stringify({ madeOn: today, note: 'Billing screen values read back from the local database right after building. Sign in with a magic link made by an admin tool; none is stored here.', users: manifest }, null, 2) + '\n');
  console.log(`built ${manifest.length} UI sample users for ${today}; manifest scripts/billing-sim/ui-samples.json`);
}

(async () => {
  await db.exec(SESSION_SQL);
  if (process.argv.includes('--remove')) { await remove(); console.log('removed UI sample users'); }
  else await build();
  db.close();
})().catch((e) => { console.error(e); process.exit(2); });
