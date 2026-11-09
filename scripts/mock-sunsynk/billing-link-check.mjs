#!/usr/bin/env node
// Plan check through the real link-sunsynk (SOLAR-208): guards a and b, and Family's room
// (5 plants + any extra plants still held, 0156). Local stack with the mock SunSynk server only. Exit code decides.
//
//   node scripts/mock-sunsynk/billing-link-check.mjs
// Reads API_URL, SERVICE_ROLE_KEY and ANON_KEY from `supabase status` unless set in the env.
// PSQL: psql to use (default: libpq's, else psql on PATH). LINK_URL points it at a function
// served elsewhere (default: the local gateway).
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
const status = process.env.SERVICE_ROLE_KEY ? {} : Object.fromEntries(execFileSync("supabase", ["status", "-o", "env"], { encoding: "utf8" })
  .split("\n").map((l) => l.match(/^(\w+)="?(.*?)"?$/)).filter(Boolean).map((m) => [m[1], m[2]]));
const env = (k) => (process.env[k] || status[k] || "").replace(/"/g, "");
const API = env("API_URL") || "http://127.0.0.1:55321";
const FN = process.env.LINK_URL || `${API}/functions/v1/link-sunsynk`;
const SERVICE = env("SERVICE_ROLE_KEY"), ANON = env("ANON_KEY");
const DB = process.env.DB_URL?.replace(/"/g, "") || "postgresql://postgres:postgres@127.0.0.1:55322/postgres";
const PSQL = process.env.PSQL || (existsSync("/opt/homebrew/opt/libpq/bin/psql") ? "/opt/homebrew/opt/libpq/bin/psql" : "psql");
const sql = (q) => execFileSync(PSQL, [DB, "-XAtc", q]).toString().trim();
let fail = 0;
const check = (ok, what) => { console.log((ok ? "  ok   " : "  FAIL ") + what); if (!ok) fail++; };
const tag = Date.now();
async function user(name) {
  const email = `${name}-${tag}@billing.test`;
  const h = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json" };
  const u = await (await fetch(`${API}/auth/v1/admin/users`, { method: "POST", headers: h, body: JSON.stringify({ email, password: "devpassword123", email_confirm: true }) })).json();
  const s = await (await fetch(`${API}/auth/v1/token?grant_type=password`, { method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" }, body: JSON.stringify({ email, password: "devpassword123" }) })).json();
  return { id: u.id, jwt: s.access_token };
}
async function link(u, username, extra = {}) {
  const r = await fetch(FN, { method: "POST", headers: { apikey: ANON, Authorization: `Bearer ${u.jwt}`, "Content-Type": "application/json" }, body: JSON.stringify({ username, password: "x", ...extra }) });
  return { status: r.status, body: await r.json().catch(() => null) };
}
const accounts = (u) => Number(sql(`select count(*) from private.sunsynk_accounts where user_id = '${u.id}'`));
const plants = (u, paused) => Number(sql(`select count(*) from public.plant_users where user_id = '${u.id}' and paused = ${paused}`));

const u1 = await user("free1"), u2 = await user("free2"), u3 = await user("family"), u4 = await user("family5");
console.log("Free user");
let r = await link(u1, "solo@mock");
check(r.status === 200 && plants(u1, false) === 1 && !r.body?.paused?.length, `first plant linked, active: ${r.status}`);
check(sql(`select count(*) from private.free_week_logins where user_id = '${u1.id}'`) === "1", "free week recorded for the account");
r = await link(u1, "solo@mock");
check(r.status === 200 && plants(u1, false) === 1, `same login again (relink) still allowed: ${r.status}`);
r = await link(u1, "installer@mock");
check(r.status === 200 && r.body?.paused?.length === 4 && plants(u1, false) === 1 && plants(u1, true) === 4,
  `installer login: its 4 new plants link paused: ${r.status} paused=${JSON.stringify(r.body?.paused)}`);
check(accounts(u1) === 2, "both logins listed");
console.log("Second free account");
r = await link(u2, "solo@mock");
// 0121 (SOLAR-241): every account gets one free week, on any plant, even one another account has.
check(r.status === 200 && plants(u2, false) === 1 && plants(u2, true) === 0,
  `a login another account had links and collects: ${r.status} ${r.body?.reason}`);
check(sql(`select count(*) from private.free_week_logins where user_id = '${u2.id}'`) === "1", "this account's own free week");

console.log("Family user");
const nd = sql(`select (current_date + 15)::date`);
sql(`insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values ('${u3.id}', 'family', 'monthly', extract(day from current_date + 15)::int, '${nd}')`);
// Family's price at the offer the account pays at, with n extra plants held
const price = (u, n) => Number(sql(`select public.billing_amount('family', 'monthly', ${n}, private.billing_offer('${u.id}', '${nd}'))`));
r = await link(u3, "export@mock");
check(r.status === 200 && plants(u3, false) === 2, `2 plants: ${r.status}`);
r = await link(u3, "shared@mock");
r = await link(u3, "nobatt@mock");
check(r.status === 200 && plants(u3, false) === 4, `4 plants covered: ${r.status}`);
// 0129: no cost question at link time. 0156: Family covers 5; a plant past that links stopped.
r = await link(u3, "farm@mock");
check(r.status === 200 && plants(u3, false) === 5 && plants(u3, true) === 1, `farm's 2 plants: the 5th collects, the 6th links stopped: ${r.status} ${JSON.stringify(r.body)}`);
check(Number(sql(`select public.billing_amount_due('${u3.id}')`)) === price(u3, 0), `stopped plant not billed: R${price(u3, 0)}`);
// 0156: extra plants are no longer sold.
let sold = true; try { execFileSync(PSQL, [DB, "-XAtc", `select public.billing_charge_open('${u3.id}', 'family', null, 1)`], { stdio: "pipe" }); } catch { sold = false; }
check(!sold, "a charge for an extra plant is refused");
// An account still holding extras keeps them on top of the 5 (set here, as regress.mjs does).
sql(`update private.billing set extra_plants = 1 where user_id = '${u3.id}'`);
const stoppedId = sql(`select plant_id from public.plant_users where user_id = '${u3.id}' and paused limit 1`);
const st = await (await fetch(`${API}/rest/v1/rpc/api_plant_start`, { method: "POST", headers: { apikey: ANON, Authorization: `Bearer ${u3.jwt}`, "Content-Type": "application/json" }, body: JSON.stringify({ p_plant: Number(stoppedId) }) })).status;
check(st < 300 && plants(u3, false) === 6 && plants(u3, true) === 0, `1 extra held: the stopped plant starts: ${st}`);
check(Number(sql(`select public.billing_amount_due('${u3.id}')`)) === price(u3, 1), `next bill Family + 1 extra: R${price(u3, 1)}`);
sql(`delete from private.link_attempts where user_id = '${u3.id}'`); // past the 5-an-hour link cap (0107)
r = await link(u3, "business@mock");
check(r.status === 200 && plants(u3, false) === 6 && plants(u3, true) === 3, `room full: business's 3 plants link stopped: ${r.status} paused=${JSON.stringify(r.body?.paused)}`);
check(Number(sql(`select public.billing_amount_due('${u3.id}')`)) === price(u3, 1), "linking does not change the bill");

console.log("Family user, one login with 5 plants");
sql(`insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values ('${u4.id}', 'family', 'monthly', extract(day from current_date + 15)::int, '${nd}')`);
r = await link(u4, "installer@mock");
check(r.status === 200 && plants(u4, false) === 5 && !r.body?.paused?.length, `5 plants on one login all collect: ${r.status} paused=${JSON.stringify(r.body?.paused)}`);
// 0127 (SOLAR-264): a paid account's first link starts its week too, so a later move to Free trims.
check(sql(`select count(*) from private.free_week_logins where user_id = '${u3.id}'`) === "1", "paid links record the free week");

for (const u of [u1, u2, u3, u4]) await fetch(`${API}/auth/v1/admin/users/${u.id}`, { method: "DELETE", headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } });
sql(`delete from private.free_week_logins where sunsynk_username = 'solo@mock'`);
console.log(fail ? `${fail} FAILED` : "PASS");
process.exit(fail ? 1 : 0);
