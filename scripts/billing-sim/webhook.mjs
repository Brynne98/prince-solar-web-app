// Signed Paystack events against the local billing webhook (SOLAR-264 round 3). Users wh-N@s264.test, deleted at the end.
// Needs the edge runtime served with PAYSTACK_SECRET_KEY=s264-local-dummy-key and PAYSTACK_URL at mock-paystack.mjs
// (port 4500). Exit 0 = every check held, 1 = findings. Checks: W1 a lost dispute is recorded and the account is past due;
// W2 a full hand refund leaves the payment list, the plan stays; W3 a partial hand refund keeps its amount; W4 a refund
// before charge.success does not leave the plan applied; W5 delete is refused with a paid plan, and a payment for an
// account deleted anyway (an old card page) is refunded; W6 a wrong-amount payment resent is refunded once and
// answered 200 each time.
import { createHmac } from 'node:crypto';
import { execFileSync } from 'node:child_process';
const PSQL = '/opt/homebrew/opt/libpq/bin/psql', DB = 'postgresql://postgres:postgres@127.0.0.1:55322/postgres';
const KEY = 's264-local-dummy-key', URL = 'http://127.0.0.1:55321/functions/v1/billing/webhook';
const q = (sql) => execFileSync(PSQL, ['-X', '-At', '-v', 'ON_ERROR_STOP=1', DB, '-c', sql], { encoding: 'utf8' }).trim();
const send = async (ev) => { const raw = JSON.stringify(ev); const r = await fetch(URL, { method: 'POST', body: raw, headers: { 'x-paystack-signature': createHmac('sha512', KEY).update(raw).digest('hex'), 'content-type': 'application/json' } }); return r.status; };
const U = (n) => `00000000-0000-4000-9400-00000000000${n}`;
const out = [];
try {
  q(`insert into auth.users (id, email, aud, role, instance_id, confirmation_token, recovery_token, email_change_token_new, email_change)
     select ('00000000-0000-4000-9400-00000000000'||i)::uuid, 'wh-'||i||'@s264.test', 'authenticated','authenticated','00000000-0000-0000-0000-000000000000','','','','' from generate_series(1,5) i;
     insert into private.billing (user_id, plan, period, billing_day, next_billing_date, card, card_email)
     select ('00000000-0000-4000-9400-00000000000'||i)::uuid, 'home', 'monthly', 10, '2026-11-10', '{"authorization_code":"AUTH_wh","reusable":true}', 'wh-'||i||'@s264.test' from generate_series(1,5) i;
     insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on, status, settled_at)
     values ('psh_wh1ren','${U(1)}','renewal','home','monthly',99,'2026-10-10','2026-10-10','paid',now()),
            ('psh_wh2ren','${U(2)}','renewal','home','monthly',99,'2026-10-10','2026-10-10','paid',now()),
            ('psh_wh3ren','${U(3)}','renewal','home','monthly',99,'2026-10-10','2026-10-10','paid',now());`);
  // W1 dispute
  out.push(['W1 dispute.create status', await send({ event: 'charge.dispute.create', data: { id: 1, status: 'awaiting-merchant-feedback', refund_amount: 9900, currency: 'ZAR', transaction: { reference: 'psh_wh1ren', amount: 9900 } } })]);
  out.push(['W1 dispute.resolve status', await send({ event: 'charge.dispute.resolve', data: { id: 1, status: 'lost', refund_amount: 9900, currency: 'ZAR', resolution: 'declined', transaction: { reference: 'psh_wh1ren', amount: 9900 } } })]);
  out.push(['W1 after dispute lost', q(`select b.plan||' '||b.state||' charge='||c.status||' refunded_at='||coalesce(c.refunded_at::text,'null')||' error='||coalesce(c.error,'null') from private.billing b join private.billing_charges c on c.user_id=b.user_id where c.reference='psh_wh1ren'`)]);
  // W2 full hand refund
  out.push(['W2 refund.processed full', await send({ event: 'refund.processed', data: { status: 'processed', amount: 9900, currency: 'ZAR', transaction_reference: 'psh_wh2ren' } })]);
  out.push(['W2 after', q(`select b.plan||' '||b.state||' refunded_at set='||(c.refunded_at is not null)||' error='||coalesce(c.error,'null') from private.billing b join private.billing_charges c on c.user_id=b.user_id where c.reference='psh_wh2ren'`)]);
  out.push(['W2 status payments', q(`select set_config('request.jwt.claims', json_build_object('sub','${U(2)}','role','authenticated')::text, false); select public.api_billing_status()->'payments'`).split('\n').pop()]);
  // W3 partial hand refund R40 of R99
  out.push(['W3 refund.processed partial', await send({ event: 'refund.processed', data: { status: 'processed', amount: '4000', currency: 'ZAR', transaction_reference: 'psh_wh3ren', refund_reference: 'rf_wh3' } })]);
  out.push(['W3 after', q(`select 'refunded_cents='||coalesce(refunded_cents::text,'null')||' amount kept='||amount||' error='||coalesce(error,'null') from private.billing_charges where reference='psh_wh3ren'`)]);
  // W4 refund event before charge.success (an upgrade Home->Family, card page)
  const ref4 = JSON.parse(q(`select public.billing_charge_open('${U(4)}','family',null,null)`)).reference;
  const amt4 = q(`select amount from private.billing_charges where reference='${ref4}'`);
  out.push(['W4 refund.processed first', await send({ event: 'refund.processed', data: { status: 'processed', amount: amt4 * 100, currency: 'ZAR', transaction_reference: ref4 } })]);
  out.push(['W4 charge.success after', await send({ event: 'charge.success', data: { status: 'success', reference: ref4, amount: amt4 * 100, currency: 'ZAR', authorization: { authorization_code: 'AUTH_wh4', reusable: true } } })]);
  out.push(['W4 after', q(`select b.plan||' charge='||c.status||' refunded_at set='||(c.refunded_at is not null)||' error='||coalesce(c.error,'null') from private.billing b join private.billing_charges c on c.user_id=b.user_id where c.reference='${ref4}'`)]);
  // W5 card page paid after the account was deleted
  const ref5 = JSON.parse(q(`select public.billing_charge_open('${U(5)}','family',null,null)`)).reference;
  const amt5 = q(`select amount from private.billing_charges where reference='${ref5}'`);
  let refused = 'no';
  try { q(`select set_config('request.jwt.claims', json_build_object('sub','${U(5)}','role','authenticated')::text, false); select public.api_account_delete();`); }
  catch (e) { refused = /cancel your plan first|a payment is open/.test(String(e.stderr || e.message)) ? 'yes' : String(e.stderr || e.message).split('\n')[0]; }
  out.push(['W5 delete refused', refused]);
  // An account deleted anyway (before 0130, or a card page older than a day): its rows are gone.
  q(`delete from auth.users where id = '${U(5)}'`);
  const before = (await (await fetch('http://127.0.0.1:4500/stats')).json()).refunds;
  out.push(['W5 charge.success after delete', await send({ event: 'charge.success', data: { status: 'success', reference: ref5, amount: amt5 * 100, currency: 'ZAR', authorization: { authorization_code: 'AUTH_wh5', reusable: true } } })]);
  const after = (await (await fetch('http://127.0.0.1:4500/stats')).json()).refunds;
  out.push(['W5 refunds sent to Paystack', after - before, 'charge rows left', q(`select count(*) from private.billing_charges where reference='${ref5}'`)]);
  // W6 a charge.success for another amount, sent twice (Paystack resends): refunded once, answered 200 both times
  const ref6 = JSON.parse(q(`select public.billing_charge_open('${U(4)}','family',null,null)`)).reference;
  const r6 = Number(q(`select amount from private.billing_charges where reference='${ref6}'`)) * 100 + 500;
  const before6 = (await (await fetch('http://127.0.0.1:4500/stats')).json()).refunds;
  const ev6 = { event: 'charge.success', data: { status: 'success', reference: ref6, amount: r6, currency: 'ZAR' } };
  out.push(['W6 wrong amount first', await send(ev6)]);
  out.push(['W6 wrong amount again', await send(ev6)]);
  out.push(['W6 refunds sent', (await (await fetch('http://127.0.0.1:4500/stats')).json()).refunds - before6]);
} finally {
  q(`delete from auth.users where email like 'wh-%@s264.test'; delete from public.email_queue where to_email like 'wh-%@s264.test';`);
  out.push(['cleanup users left', q(`select count(*) from auth.users where email like 'wh-%@s264.test'`)]);
}
for (const o of out) console.log(o.join(' | '));
const get = (k) => out.find((o) => o[0] === k) || [];
const bad = [];
const status = out.filter((o) => / status$|first$|again$|after$|after delete$|full$|partial$/.test(o[0]) && typeof o[1] === 'number');
for (const o of status) if (o[1] !== 200) bad.push(`${o[0]}: webhook answered ${o[1]}`);
if (!/past_due/.test(get('W1 after dispute lost')[1] || '')) bad.push('W1 dispute lost: account not past due');
if (!/home active/.test(get('W2 after')[1] || '') || get('W2 status payments')[1] !== '[]') bad.push(`W2 full hand refund: ${get('W2 after')[1]}, payments ${get('W2 status payments')[1]}`);
if (!/refunded_cents=4000/.test(get('W3 after')[1] || '')) bad.push(`W3 partial hand refund: ${get('W3 after')[1]}`);
if (get('W5 delete refused')[1] !== 'yes') bad.push(`W5 delete of an active Home account: ${get('W5 delete refused')[1]}`);
if (/charge=paid refunded_at=null error=null/.test(get('W1 after dispute lost')[1])) bad.push('W1 dispute lost: plan, plants and charge unchanged, nothing recorded');
if (/charge=paid refunded_at set=false error=null/.test(get('W4 after')[1])) bad.push('W4 refund before success: upgrade applied, refund lost');
if (get('W6 refunds sent')[1] !== 1) bad.push(`W6 wrong amount: ${get('W6 refunds sent')[1]} refunds, want 1`);
if (get('W5 refunds sent to Paystack')[1] === 0) bad.push('W5 paid after account delete: unknown reference, no refund');
console.log(bad.length ? 'FINDINGS\n- ' + bad.join('\n- ') : 'all held');
process.exit(bad.length ? 1 : 0);
