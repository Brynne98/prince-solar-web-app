// Scale test of POST /billing/run (SOLAR-264): N Home renewals due today against mock-paystack.mjs.
// Needs the edge runtime served with PAYSTACK_URL pointing at the mock and any PAYSTACK_SECRET_KEY.
//   node scripts/billing-sim/scale.mjs [--users 3000] [--mock http://127.0.0.1:4500] [--keep]
// Calls the route as pg_cron does, one call after another, until nothing is due; a charge left
// open is handed out again only after 10 minutes, so its claim is moved 11 minutes back (as the
// next cron call would find it). Then checks every charge against what the mock charged.
// Exit 0 = every check held. The scale users (scale-N@sim.test) are deleted at the end.
import { execFileSync } from 'node:child_process';
import { Db } from './db.mjs';

const arg = (k, d) => { const i = process.argv.indexOf('--' + k); return i > 0 ? process.argv[i + 1] : d; };
const N = Number(arg('users', 3000)), MOCK = arg('mock', 'http://127.0.0.1:4500');
const env = Object.fromEntries(execFileSync('supabase', ['status', '-o', 'env'], { encoding: 'utf8' })
  .split('\n').map((l) => l.match(/^(\w+)="?(.*?)"?$/)).filter(Boolean).map((m) => [m[1], m[2]]));
const API = env.API_URL, KEY = env.SERVICE_ROLE_KEY;
const db = new Db();
const bad = [];

await db.exec(`insert into auth.users (id, email, aud, role, confirmation_token, recovery_token, email_change_token_new, email_change)
  select gen_random_uuid(), 'scale-' || i || '@sim.test', 'authenticated', 'authenticated', '', '', '', '' from generate_series(1, ${N}) i;
insert into private.billing (user_id, plan, period, billing_day, next_billing_date, card, card_email)
  select id, 'home', 'monthly', extract(day from private.billing_today())::int, private.billing_today(),
         jsonb_build_object('authorization_code', 'AUTH_' || id, 'reusable', true, 'last4', '4081'), email
    from auth.users where email like 'scale-%@sim.test';`);
const mine = `user_id in (select id from auth.users where email like 'scale-%@sim.test')`;
console.log(`${N} Home renewals due ${(await db.exec('select private.billing_today()'))[0]}`);

const calls = [];
const t0 = Date.now();
for (let k = 0; k < 40; k++) {
  const t = Date.now();
  const r = await fetch(`${API}/functions/v1/billing/run`, { method: 'POST', headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }, body: '{}' });
  const out = await r.json().catch(() => ({}));
  calls.push({ call: k + 1, http: r.status, seconds: +((Date.now() - t) / 1000).toFixed(1), ...out });
  console.log(JSON.stringify(calls.at(-1)));
  if (r.status !== 200) { bad.push(`call ${k + 1}: HTTP ${r.status}`); break; }
  if (out.due === 0) {
    const open = Number((await db.exec(`select count(*) from private.billing_charges where ${mine} and status = 'pending'`))[0]);
    if (!open) break;
    // as the next cron call 10 minutes on would find them
    await db.exec(`update private.billing_charges set claimed_at = now() - interval '11 minutes' where ${mine} and status = 'pending'`);
  }
}
const wall = (Date.now() - t0) / 1000;

const rows = await db.json(`select coalesce(jsonb_agg(jsonb_build_object('reference', reference, 'status', status, 'error', error, 'user', user_id)), '[]')
  from private.billing_charges where ${mine}`);
const mails = Number((await db.exec(`select count(*) from public.email_queue where ${mine} and kind = 'bill_failed'`))[0]);
const pastDue = Number((await db.exec(`select count(*) from private.billing where ${mine} and state = 'past_due'`))[0]);
const mock = await (await fetch(`${MOCK}/stats`)).json();
const m = new Map(mock.transactions.map((t) => [t.reference, t]));

const by = (s) => rows.filter((r) => r.status === s);
if (rows.length !== N) bad.push(`${rows.length} renewal charges for ${N} users`);
if (new Set(rows.map((r) => r.user)).size !== N) bad.push('a user has no charge or two');
if (by('pending').length) bad.push(`${by('pending').length} still open`);
// The mock charges a reference once and refuses it after, as Paystack does: a second try shows as tries > 1.
const retried = mock.transactions.filter((t) => t.tries > 1).length;
for (const r of rows) {
  const t = m.get(r.reference);
  if (r.status === 'paid' && t?.status !== 'success') bad.push(`${r.reference} paid in the db, ${t?.status ?? 'never charged'} at Paystack`);
  if (r.status === 'failed' && t?.status !== 'failed') bad.push(`${r.reference} failed in the db (${r.error}), ${t?.status ?? 'never charged'} at Paystack`);
}
if (m.size !== N) bad.push(`Paystack has ${m.size} transactions for ${N} renewals`);
if (mails !== by('failed').length) bad.push(`${mails} "payment failed" emails for ${by('failed').length} declined cards`);
if (pastDue !== by('failed').length) bad.push(`${pastDue} past due for ${by('failed').length} declined cards`);
const longest = Math.max(...calls.map((c) => c.seconds));
if (longest > 140) bad.push(`a call ran ${longest} s`);

console.log('\n== result ==');
console.log({ renewals: N, calls: calls.length, wallSeconds: +wall.toFixed(0), longestCallSeconds: longest,
  paid: by('paid').length, declined: by('failed').length, open: by('pending').length,
  paystack: { charged: mock.charges, duplicateRefused: mock.duplicates, verifies: mock.verifies, notFound: mock.notFound,
    hung: mock.hang, dropped: mock.drop, busy503: mock.busy, verify503: mock.verifyBusy ?? 0, maxInFlight: mock.maxInFlight, triedAgainRefused: retried }, emails: mails, pastDue });
if (!process.argv.includes('--keep')) {
  await db.exec(`delete from auth.users where email like 'scale-%@sim.test';`);
  console.log('scale users left:', (await db.exec(`select count(*) from auth.users where email like 'scale-%@sim.test'`))[0]);
}
db.close();
console.log(bad.length ? `FAIL\n  ${bad.slice(0, 20).join('\n  ')}` : 'PASS');
process.exit(bad.length ? 1 : 0);
