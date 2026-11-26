#!/usr/bin/env node
// Local staging check (SOLAR-679 F10, F11), after scripts/staging-local.sh. Signs up a new user,
// links a fake SunSynk plant through the real link-sunsynk, then waits for cron to call the
// functions and checks every call went to this stack, never production.
//   API_URL, ANON_KEY, DB_URL from `supabase status -o env`, all local.
// Paying with a test card needs Paystack's checkout page in a browser: see DEPLOY.md, Staging.
// Exit 0: all held. Exit 1: one did not.
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';

const { API_URL: API, ANON_KEY: ANON, DB_URL: DB } = process.env;
if (![API, DB].every((u) => /^(https?|postgres(ql)?):\/\/[^/]*@?(127\.0\.0\.1|localhost)[:/]/.test(u || ''))) {
  console.error('refusing: API_URL and DB_URL must be local'); process.exit(1);
}
const PSQL = process.env.PSQL || ['/opt/homebrew/opt/libpq/bin/psql'].find(existsSync) || 'psql';
const sql = (q) => execFileSync(PSQL, ['-XAtq', '-v', 'ON_ERROR_STOP=1', DB, '-c', q], { encoding: 'utf8' }).trim();
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = 0;
const check = (ok, what) => { console.log(`${ok ? 'ok  ' : 'FAIL'}  ${what}`); if (!ok) failed++; };

// sign up (local auth confirms at once)
const email = `staging-${Date.now()}@example.com`;
const su = await fetch(`${API}/auth/v1/signup`, { method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' },
  body: JSON.stringify({ email, password: 'stagingpass123' }) }).then((r) => r.json());
check(!!su.access_token, 'sign up');

// link a fake plant
const link = await fetch(`${API}/functions/v1/link-sunsynk`, { method: 'POST',
  headers: { apikey: ANON, Authorization: `Bearer ${su.access_token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'solo@mock', password: 'anything1' }) });
check(link.ok, `link a fake plant (${link.status})`);
const plants = sql(`select count(*) from public.plant_users pu join auth.users u on u.id = pu.user_id where u.email = '${email}'`);
check(Number(plants) > 0, `the plant is on the account (${plants})`);

// cron calls this stack only
check(sql(`select count(*) from cron.job where command ~ 'supabase\\.co'`) === '0', 'no cron job names a hosted address');
check(/^http:\/\/supabase_kong_[\w-]+:8000\/functions\/v1$/.test(sql('select private.functions_url()')), 'functions_url is this stack');
let ok = '0';
for (let i = 0; i < 40 && ok === '0'; i++) {
  await wait(5000);
  ok = sql(`select count(*) from private.fn_calls c join net._http_response r using (id) where c.fn = 'poll' and r.status_code = 200`);
}
check(ok !== '0', 'cron called the local poll function and it answered 200');
process.exit(failed ? 1 : 0);
