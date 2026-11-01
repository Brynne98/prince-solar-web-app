// Lock-order race (SOLAR-264 round 3): a card payment applying (billing_charge_paid -> billing_resume) while the
// user starts a stopped plant (api_plant_start), each in its own session, many times. Exit 0 = no deadlock, 1 = deadlock.
// A deadlock makes billing_charge_paid fail and a paid charge can stay pending, unapplied (since 0130 the
// webhook answers 500 then, so Paystack sends the event again). Commits rows for users race-N@s264.test and deletes them at the end.
// --removal (0132): the daily run deleting a Free account's booked plants while the user pays a start that
// keeps them. Before 0132 the run took the plant lock, then the billing row; the payment the other way round.
// --shared (0132): a payment starting a user's stopped plants while another user's sync of the same plants runs.
// billing_resume took plant locks in link order, plant_users_upsert in plant id order.
//   node scripts/billing-sim/race.mjs [--rounds 20] [--removal | --shared]
import { spawn, execFileSync } from 'node:child_process';
import { PSQL, DB_URL } from './db.mjs';
const ROUNDS = Number(process.argv[process.argv.indexOf('--rounds') + 1] || 20) || 20;
const q = (sql) => execFileSync(PSQL, ['-X', '-At', '-v', 'ON_ERROR_STOP=1', DB_URL, '-c', sql], { encoding: 'utf8' }).trim();
const bg = (sql) => new Promise((res) => { const p = spawn(PSQL, ['-X', '-At', DB_URL, '-c', sql]); let o = ''; p.stdout.on('data', (d) => o += d); p.stderr.on('data', (d) => o += d); p.on('exit', () => res(o)); });
const REMOVAL = process.argv.includes('--removal'), SHARED = process.argv.includes('--shared');
if (REMOVAL && SHARED) { console.error('one of --removal and --shared'); process.exit(2); }
// It commits rows and calls billing_run for the whole database: local only.
if (!/@(127\.0\.0\.1|localhost):/.test(DB_URL)) { console.error(`not a local database: ${DB_URL}`); process.exit(2); }
let deadlocks = 0, unapplied = 0, deleted = 0;
const HELPER = '00000000-0000-4000-9500-999999999999';
try {
  q(`insert into auth.users (id, email, aud, role, confirmation_token, recovery_token, email_change_token_new, email_change)
       values ('${HELPER}', 'race-helper@s264.test', 'authenticated', 'authenticated', '', '', '', '');
     insert into private.billing (user_id, plan, comped) values ('${HELPER}', 'family', true);`);
  for (let i = 0; REMOVAL && i < ROUNDS; i++) {
    const u = `00000000-0000-4000-9500-${String(i).padStart(12, '0')}`;
    const pl = (k) => 95000000 + i * 10 + k;
    q(`insert into auth.users (id, email, aud, role, confirmation_token, recovery_token, email_change_token_new, email_change)
         values ('${u}', 'race-${i}@s264.test', 'authenticated', 'authenticated', '', '', '', '');
       insert into private.billing (user_id, plan, plants_to_remove, remove_on)
         values ('${u}', 'free', '{${pl(2)},${pl(3)}}', private.billing_today());
       insert into public.plant_users (plant_id, user_id, plant_name, linked_at, paused)
         select ${pl(0)} + k, '${u}', 'r' || k, now() + k * interval '1 s', k > 1 from generate_series(1, 3) k;
       insert into public.plant_users (plant_id, user_id, plant_name) select ${pl(0)} + k, '${HELPER}', 'h' from generate_series(1, 3) k;`);
    const ref = q(`select public.billing_charge_open('${u}', 'family', 'monthly')->>'reference'`);
    const [a, b] = await Promise.all([
      bg(`begin; select private.billing_lock('${u}'); select 1 from private.billing where user_id = '${u}' for update; select pg_sleep(0.6); select public.billing_charge_paid('${ref}', null, true, null); commit;`),
      new Promise((r) => setTimeout(r, 150)).then(() => bg(`begin; select public.billing_run(private.billing_today()); commit;`)),
    ]);
    if (/deadlock detected/.test(a + b)) deadlocks++;
    if (q(`select status from private.billing_charges where reference = '${ref}'`) === 'pending') unapplied++;
    if (Number(q(`select count(*) from public.plant_users where user_id = '${u}'`)) < 3) deleted++;
  }
  const acc = SHARED ? q(`insert into private.sunsynk_accounts (user_id, sunsynk_username) values ('${HELPER}', 'race-helper@login.test') returning id`).split('\n')[0] : null;
  for (let i = 0; SHARED && i < ROUNDS; i++) {
    const u = `00000000-0000-4000-9500-${String(i).padStart(12, '0')}`;
    const hi = 95000000 + i * 10 + 8, lo = 95000000 + i * 10 + 2, one = 95000000 + i * 10 + 1;
    q(`insert into auth.users (id, email, aud, role, confirmation_token, recovery_token, email_change_token_new, email_change)
         values ('${u}', 'race-${i}@s264.test', 'authenticated', 'authenticated', '', '', '', '');
       insert into private.billing (user_id, plan, period, billing_day, next_billing_date, card)
         values ('${u}', 'home', 'monthly', 10, private.billing_today() + 10, '{"authorization_code":"R","reusable":true}');
       insert into public.plant_users (plant_id, user_id, plant_name, linked_at, paused) values
         (${one}, '${u}', 'one', now(), false), (${hi}, '${u}', 'hi', now() + interval '1 s', true), (${lo}, '${u}', 'lo', now() + interval '2 s', true);
       insert into public.plant_users (plant_id, user_id, account_id, plant_name) values (${hi}, '${HELPER}', '${acc}', 'h'), (${lo}, '${HELPER}', '${acc}', 'h');`);
    const ref = q(`select public.billing_charge_open('${u}', 'family')->>'reference'`);
    const rows = JSON.stringify([{ plant_id: lo, plant_name: 'h' }, { plant_id: hi, plant_name: 'h' }]);
    const [a, b] = await Promise.all([
      bg(`begin; select pg_advisory_xact_lock(${lo}); select pg_sleep(0.6); select public.plant_users_upsert('${HELPER}', '${acc}', '${rows}'::jsonb); commit;`),
      new Promise((r) => setTimeout(r, 150)).then(() => bg(`begin; select public.billing_charge_paid('${ref}', null, true, null); commit;`)),
    ]);
    if (/deadlock detected/.test(a + b)) deadlocks++;
    if (q(`select status from private.billing_charges where reference = '${ref}'`) === 'pending') unapplied++;
  }
  for (let i = 0; !REMOVAL && !SHARED && i < ROUNDS; i++) {
    const u = `00000000-0000-4000-9500-${String(i).padStart(12, '0')}`;
    q(`insert into auth.users (id, email, aud, role, confirmation_token, recovery_token, email_change_token_new, email_change)
         values ('${u}', 'race-${i}@s264.test', 'authenticated', 'authenticated', '', '', '', '');
       insert into private.billing (user_id, plan, period, billing_day, next_billing_date, card)
         values ('${u}', 'family', 'monthly', 10, private.billing_today() + 10, '{"authorization_code":"R","reusable":true}');
       insert into public.plant_users (plant_id, user_id, plant_name, linked_at, paused)
         select 95000000 + ${i} * 10 + k, '${u}', 'r' || k, now() + k * interval '1 s', k > 3 from generate_series(1, 5) k;`);
    const ref = q(`select public.billing_charge_open('${u}', 'family', null, 1)->>'reference'`);
    const plant = 95000000 + i * 10 + 4;
    // A comped helper collects the same plants, so no start fills them (plant_start_fill posts to the hosted functions).
    q(`insert into public.plant_users (plant_id, user_id, plant_name) select 95000000 + ${i} * 10 + k, '${HELPER}', 'h' from generate_series(1, 5) k`);
    const [a, b] = await Promise.all([
      bg(`begin; select private.billing_lock('${u}'); select pg_sleep(0.6); select public.billing_charge_paid('${ref}', null, true, null); commit;`),
      new Promise((r) => setTimeout(r, 150)).then(() => bg(`begin; select set_config('request.jwt.claims', json_build_object('sub','${u}','role','authenticated')::text, true); select public.api_plant_start(${plant}); select pg_sleep(0.3); commit;`)),
    ]);
    if (/deadlock detected/.test(a + b)) deadlocks++;
    if (q(`select status from private.billing_charges where reference = '${ref}'`) === 'pending') unapplied++;
  }
} finally {
  q(`delete from private.billing_charges where user_id in (select id from auth.users where email like 'race-%@s264.test');
     delete from public.plant_users where user_id in (select id from auth.users where email like 'race-%@s264.test');
     delete from private.sunsynk_accounts where user_id in (select id from auth.users where email like 'race-%@s264.test');
     delete from auth.users where email like 'race-%@s264.test';`);
}
console.log(`${ROUNDS} rounds${REMOVAL ? ' (removal)' : SHARED ? ' (shared)' : ''}: ${deadlocks} deadlocks, ${unapplied} paid charges left pending (unapplied)` +
  (REMOVAL ? `, ${deleted} accounts lost plants they paid to keep` : ''));
process.exit(deadlocks || deleted || unapplied ? 1 : 0);
