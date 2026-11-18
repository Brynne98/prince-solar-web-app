// The SOLAR-584 server events, end to end against the local stack (exit code decides). Users ev-*@s584.test,
// deleted at the end. Needs, all local:
//   - the mock SunSynk (scripts/mock-sunsynk/server.js, :4400) and mock-paystack.mjs (:4500, --decline 0 --hang 0 --drop 0 --busy 0)
//   - a stand-in PostHog on :4600 that keeps what is posted: GET /events, POST /reset
//   - link-sunsynk, claim-share and billing served with POSTHOG_URL=http://127.0.0.1:4600/e/, PAYSTACK_URL at the mock,
//     PAYSTACK_SECRET_KEY=s584-local-dummy-key, SUNSYNK_SHARE_USERNAME=installer@mock (FN_LINK, FN_SHARE, FN_BILLING give
//     their addresses; default the local gateway)
// Checks: E1 a first link counts no plant seen before; E2 the same login on a new account after a delete counts it;
// E3 a plant another account holds is not counted; E4 a relink sends again; E5 a two-plant login counts 2;
// E6-E7 the same through a share claim; P1 a first payment from a lapsed free week is not returning; P2 a payment
// after an earlier paid plan ended is returning with its days; P3 Paystack's notice sent twice gives one event,
// and the second never says returning false; P4 a renewal sends none.
import { createHmac } from 'node:crypto';
import { execFileSync } from 'node:child_process';
const PSQL = '/opt/homebrew/opt/libpq/bin/psql', DB = 'postgresql://postgres:postgres@127.0.0.1:55322/postgres';
const q = (sql) => execFileSync(PSQL, ['-X', '-At', '-v', 'ON_ERROR_STOP=1', DB, '-c', sql], { encoding: 'utf8' }).trim();
const status = Object.fromEntries(execFileSync('supabase', ['status', '-o', 'env'], { encoding: 'utf8' })
  .split('\n').map((l) => l.match(/^(\w+)="?(.*?)"?$/)).filter(Boolean).map((m) => [m[1], m[2]]));
const API = 'http://127.0.0.1:55321', SERVICE = status.SERVICE_ROLE_KEY, ANON = status.ANON_KEY;
const FN_LINK = process.env.FN_LINK || `${API}/functions/v1/link-sunsynk`;
const FN_SHARE = process.env.FN_SHARE || `${API}/functions/v1/claim-share`;
const FN_BILLING = process.env.FN_BILLING || `${API}/functions/v1/billing`;
const PH = process.env.PH || 'http://127.0.0.1:4600', KEY = 's584-local-dummy-key';
const PLANTS = [6006, 6008, 6009, 6002];   // mock plants these checks link: their weeks are removed at the end

let fail = 0;
const check = (ok, what, got) => { console.log((ok ? '  ok   ' : '  FAIL ') + what + (ok ? '' : `: ${JSON.stringify(got)}`)); if (!ok) fail++; };
const tag = Date.now(), made = [];
async function user(name) {
  const email = `ev-${name}-${tag}@s584.test`, h = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' };
  const u = await (await fetch(`${API}/auth/v1/admin/users`, { method: 'POST', headers: h, body: JSON.stringify({ email, password: 'devpassword123', email_confirm: true }) })).json();
  const s = await (await fetch(`${API}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password: 'devpassword123' }) })).json();
  made.push(u.id);
  return { id: u.id, jwt: s.access_token };
}
const post = async (url, u, body) => { const r = await fetch(url, { method: 'POST', headers: { apikey: ANON, Authorization: `Bearer ${u.jwt}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) }); return { status: r.status, body: await r.json().catch(() => null) }; };
const link = (u, username) => post(FN_LINK, u, { username, password: 'x' });
const claim = (u, ref) => post(FN_SHARE, u, { ref: String(ref) });
const reset = () => fetch(`${PH}/reset`, { method: 'POST' });
const events = async (name, who) => (await (await fetch(`${PH}/events`)).json()).filter((e) => e.event === name && (!who || e.distinct_id === who));
const remove = async (u) => { await post(`${API}/rest/v1/rpc/api_account_delete`, u, {}); q(`delete from auth.users where id = '${u.id}'`); };
const notice = async (ev) => { const raw = JSON.stringify(ev); const r = await fetch(`${FN_BILLING}/webhook`, { method: 'POST', body: raw, headers: { 'x-paystack-signature': createHmac('sha512', KEY).update(raw).digest('hex'), 'content-type': 'application/json' } }); return r.status; };
const paid = (ref) => { const amt = Number(q(`select amount from private.billing_charges where reference = '${ref}'`)); return notice({ event: 'charge.success', data: { status: 'success', reference: ref, amount: amt * 100, currency: 'ZAR', paid_at: new Date().toISOString(), authorization: { authorization_code: 'AUTH_s584', reusable: true }, customer: { email: 'card@s584.test' } } }); };

const weeksBefore = q(`select count(*) from private.plant_week where plant_id in (${PLANTS})`);
if (weeksBefore !== '0') { console.error(`plants ${PLANTS} already had a week on this database; the counts would be off`); process.exit(2); }
try {
  console.log('Link');
  await reset();
  const a = await user('a');
  let r = await link(a, 'beach@mock');
  let e = await events('plants_linked_done', a.id);
  check(r.status === 200 && e.length === 1 && e[0].properties.via === 'login' && e[0].properties.count === 1 && e[0].properties.seen_before === 0, 'E1 first link: seen_before 0', { status: r.status, e: e.map((x) => x.properties) });
  await remove(a);
  const b = await user('b');
  r = await link(b, 'beach@mock');
  e = await events('plants_linked_done', b.id);
  check(r.status === 200 && e.length === 1 && e[0].properties.seen_before === 1, 'E2 deleted and made again: seen_before 1', { status: r.status, e: e.map((x) => x.properties) });
  const c = await user('c');
  r = await link(c, 'beach@mock');
  e = await events('plants_linked_done', c.id);
  check(r.status === 200 && e.length === 1 && e[0].properties.seen_before === 0, 'E3 plant another account holds: seen_before 0', { status: r.status, e: e.map((x) => x.properties) });
  r = await link(b, 'beach@mock');
  e = await events('plants_linked_done', b.id);
  check(r.status === 200 && e.length === 2 && new Set(e.map((x) => x.uuid)).size === 2, 'E4 a relink sends a second event', { status: r.status, n: e.length });
  const d = await user('d');
  r = await link(d, 'farm@mock');
  e = await events('plants_linked_done', d.id);
  check(r.status === 200 && e.length === 1 && e[0].properties.count === 2 && e[0].properties.seen_before === 0, 'E5 two-plant login: count 2, seen_before 0', { status: r.status, e: e.map((x) => x.properties) });
  e = (await (await fetch(`${PH}/events`)).json()).filter((x) => x.event === 'plants_linked_done');
  check(e.every((x) => !JSON.stringify(x).includes('@mock') && !JSON.stringify(x).includes('@s584.test')), 'no login or email in any event', e.length);

  console.log('Share claim');
  const s1 = await user('s1');
  r = await claim(s1, 6002);
  e = await events('plants_linked_done', s1.id);
  check(r.status === 200 && e.length === 1 && e[0].properties.via === 'share' && e[0].properties.seen_before === 0, 'E6 first claim: via share, seen_before 0', { status: r.status, body: r.body, e: e.map((x) => x.properties) });
  await remove(s1);
  const s2 = await user('s2');
  r = await claim(s2, 6002);
  e = await events('plants_linked_done', s2.id);
  check(r.status === 200 && e.length === 1 && e[0].properties.seen_before === 1, 'E7 claimed again after a delete: seen_before 1', { status: r.status, body: r.body, e: e.map((x) => x.properties) });

  console.log('Payments');
  const g = await user('g'), h = await user('h'), k = await user('k');
  // g: never paid, its free week lapsed 20 days ago (0205 gives that an ended_at)
  q(`insert into private.billing (user_id, ended_at) values ('${g.id}', now() - interval '20 days')
       on conflict (user_id) do update set ended_at = excluded.ended_at`);
  // h: paid Home before, that plan ended 12 days ago
  q(`insert into private.billing (user_id, ended_at) values ('${h.id}', now() - interval '12 days')
       on conflict (user_id) do update set ended_at = excluded.ended_at;
     insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on, status, settled_at)
     values ('psh_s584h${tag}', '${h.id}', 'start', 'home', 'monthly', 99, current_date - 60, current_date - 60, 'paid', now() - interval '60 days')`);
  const refG = JSON.parse(q(`select public.billing_charge_open('${g.id}', 'home', 'monthly')`)).reference;
  const refH = JSON.parse(q(`select public.billing_charge_open('${h.id}', 'home', 'monthly')`)).reference;
  check(q(`select string_agg(kind, ',' order by kind) from private.billing_charges where reference in ('${refG}', '${refH}')`) === 'start,start', 'both open as a start', null);
  const s1G = await paid(refG), s2G = await paid(refG);
  e = await events('plan_started_done', g.id);
  check(s1G === 200 && s2G === 200 && e.length === 1 && e[0].properties.returning === false && e[0].properties.days_since_plan === null,
    'P1 first payment after a lapsed free week: returning false', { s1G, s2G, e: e.map((x) => x.properties) });
  const s1H = await paid(refH), s2H = await paid(refH);
  e = await events('plan_started_done', h.id);
  check(s1H === 200 && s2H === 200 && e.length === 1 && e[0].properties.returning === true && e[0].properties.days_since_plan === 12,
    'P2 paid again after a plan ended: returning true, 12 days', { s1H, s2H, e: e.map((x) => x.properties) });
  check(e.length === 1 && e[0].uuid && e[0].distinct_id === h.id, 'P3 notice sent twice: one event, never returning false', e.length);
  check(q(`select plan from private.billing where user_id = '${h.id}'`) === 'home', 'the payment applied', null);
  // k: on Home, upgrades to Family
  q(`insert into private.billing (user_id, plan, period, billing_day, next_billing_date, card, card_email)
       values ('${k.id}', 'home', 'monthly', 10, current_date + 20, '{"authorization_code":"AUTH_s584","reusable":true}', 'k@s584.test')
       on conflict (user_id) do update set plan = 'home', period = 'monthly'`);
  const refK = JSON.parse(q(`select public.billing_charge_open('${k.id}', 'family', null, null)`)).reference;
  const sK = await paid(refK);
  e = await events('plan_started_done', k.id);
  check(sK === 200 && e.length === 0 && q(`select plan from private.billing where user_id = '${k.id}'`) === 'family',
    'P4 an upgrade applies and sends no plan_started_done', { sK, n: e.length, kind: q(`select kind from private.billing_charges where reference = '${refK}'`) });
} finally {
  for (const id of made) q(`delete from auth.users where id = '${id}'`);
  q(`delete from private.plant_week where plant_id in (${PLANTS})`);
}
console.log(fail ? `${fail} failed` : 'all passed');
process.exit(fail ? 1 : 0);
