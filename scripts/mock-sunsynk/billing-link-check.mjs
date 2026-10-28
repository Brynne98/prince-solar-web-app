#!/usr/bin/env node
// Plan check through the real link-sunsynk (SOLAR-208): guards a and b, the 4th-plant
// cost confirm. Local stack with the mock SunSynk server only. Exit code decides.
//
//   eval "$(supabase status -o env | grep -E '^(API_URL|SERVICE_ROLE_KEY|ANON_KEY)=')"
//   node scripts/mock-sunsynk/billing-link-check.mjs
// LINK_URL points it at a function served elsewhere (default: the local gateway).
import { execFileSync } from "node:child_process";
const API = (process.env.API_URL || "http://127.0.0.1:55321").replace(/"/g, "");
const FN = process.env.LINK_URL || `${API}/functions/v1/link-sunsynk`;
const SERVICE = (process.env.SERVICE_ROLE_KEY || "").replace(/"/g, ""), ANON = (process.env.ANON_KEY || "").replace(/"/g, "");
const DB = process.env.DB_URL?.replace(/"/g, "") || "postgresql://postgres:postgres@127.0.0.1:55322/postgres";
const sql = (q) => execFileSync(process.env.PSQL || "psql", [DB, "-XAtc", q]).toString().trim();
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

const u1 = await user("free1"), u2 = await user("free2"), u3 = await user("family");
console.log("Free user");
let r = await link(u1, "solo@mock");
check(r.status === 200 && plants(u1, false) === 1 && !r.body?.paused?.length, `first plant linked, active: ${r.status}`);
check(sql(`select user_id from private.free_week_logins where sunsynk_username = 'solo@mock'`) === u1.id, "free week recorded for the login");
r = await link(u1, "solo@mock");
check(r.status === 200 && plants(u1, false) === 1, `same login again (relink) still allowed: ${r.status}`);
r = await link(u1, "installer@mock");
check(r.status === 200 && r.body?.paused?.length === 4 && plants(u1, false) === 1 && plants(u1, true) === 4,
  `installer login: its 4 new plants link paused: ${r.status} paused=${JSON.stringify(r.body?.paused)}`);
check(accounts(u1) === 2, "both logins listed");
console.log("Second free account");
r = await link(u2, "solo@mock");
check(r.status === 200 && r.body?.reason === "free_week_used" && plants(u2, true) === 1 && plants(u2, false) === 0,
  `login that had its free week elsewhere links paused: ${r.status} ${r.body?.reason}`);
check(sql(`select count(*) from private.free_week_logins where user_id = '${u2.id}'`) === "0", "no second free week");

console.log("Family user");
const nd = sql(`select (current_date + 15)::date`);
sql(`insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values ('${u3.id}', 'family', 'monthly', extract(day from current_date + 15)::int, '${nd}')`);
r = await link(u3, "export@mock");
check(r.status === 200 && plants(u3, false) === 2, `2 plants: ${r.status}`);
r = await link(u3, "shared@mock");
check(r.status === 200 && plants(u3, false) === 3, `3rd plant covered: ${r.status}`);
r = await link(u3, "nobatt@mock");
check(r.status === 402 && r.body?.error === "confirm_cost" && r.body?.extraInverters === 1 && r.body?.dueNow > 0 && r.body?.dueNow <= 49,
  `4th plant asks to confirm: ${r.status} ${JSON.stringify(r.body)}`);
check(plants(u3, false) + plants(u3, true) === 3, "nothing linked before an answer");
r = await link(u3, "nobatt@mock", { confirmCost: "paused" });
check(r.status === 200 && plants(u3, true) === 1 && plants(u3, false) === 3, `4th plant added paused: ${r.status}`);
check(Number(sql(`select public.billing_amount_due('${u3.id}')`)) === 179, "paused plant not billed: R179");
r = await link(u3, "installer@mock");
check(r.status === 402 && r.body?.extraInverters === 2, `next new plant asks again: ${r.status} ${JSON.stringify(r.body)}`);
sql(`delete from private.link_attempts where user_id = '${u3.id}'`); // past the 5-an-hour link cap (0107)
r = await link(u3, "installer@mock", { confirmCost: true });
check(r.status === 200 && plants(u3, false) === 4, `5th plant after confirm, active: ${r.status}`);
check(Number(sql(`select public.billing_amount_due('${u3.id}')`)) === 277, "next bill R179 + 2 x R49");
check(sql(`select count(*) from private.free_week_logins where user_id = '${u3.id}'`) === "0", "paid links record no free week");

for (const u of [u1, u2, u3]) await fetch(`${API}/auth/v1/admin/users/${u.id}`, { method: "DELETE", headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } });
sql(`delete from private.free_week_logins where sunsynk_username = 'solo@mock'`);
console.log(fail ? `${fail} FAILED` : "PASS");
process.exit(fail ? 1 : 0);
