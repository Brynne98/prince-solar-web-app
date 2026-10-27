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
const plants = (u) => Number(sql(`select count(*) from public.plant_users where user_id = '${u.id}'`));

const u1 = await user("free1"), u2 = await user("free2"), u3 = await user("family");
console.log("Free user");
let r = await link(u1, "installer@mock");
check(r.status === 402 && r.body?.error === "upgrade_needed", `installer login (5 plants) refused: ${r.status} ${r.body?.error}`);
check(accounts(u1) === 0, "refused login leaves no account behind");
r = await link(u1, "solo@mock");
check(r.status === 200 && plants(u1) === 1, `first plant linked: ${r.status}`);
check(sql(`select user_id from private.free_week_logins where sunsynk_username = 'solo@mock'`) === u1.id, "free week recorded for the login");
r = await link(u1, "solo@mock");
check(r.status === 200 && plants(u1) === 1, `same login again (relink) still allowed: ${r.status}`);
r = await link(u1, "brynne@mock");
check(r.status === 403 && r.body?.error === "free_week_used", `login used elsewhere refused: ${r.status} ${r.body?.error}`);
console.log("Second free account");
r = await link(u2, "solo@mock");
check(r.status === 403 && r.body?.error === "free_week_used", `same login, new account refused: ${r.status} ${r.body?.error}`);
check(accounts(u2) === 0, "nothing stored");

console.log("Family user");
const nd = sql(`select (current_date + 15)::date`);
sql(`insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values ('${u3.id}', 'family', 'monthly', extract(day from current_date + 15)::int, '${nd}')`);
r = await link(u3, "export@mock");
check(r.status === 200 && plants(u3) === 2, `2 plants: ${r.status}`);
r = await link(u3, "shared@mock");
check(r.status === 200 && plants(u3) === 3, `3rd plant covered: ${r.status}`);
r = await link(u3, "nobatt@mock");
check(r.status === 402 && r.body?.error === "confirm_cost" && r.body?.extraInverters === 1 && r.body?.dueNow > 0 && r.body?.dueNow <= 49,
  `4th plant asks to confirm: ${r.status} ${JSON.stringify(r.body)}`);
check(plants(u3) === 3, "nothing linked before confirm");
r = await link(u3, "nobatt@mock", { confirmCost: true });
check(r.status === 200 && plants(u3) === 4, `4th plant after confirm: ${r.status}`);
check(Number(sql(`select public.billing_amount_due('${u3.id}')`)) === 228, "next bill R179 + R49");
check(sql(`select count(*) from private.free_week_logins where user_id = '${u3.id}'`) === "0", "paid links record no free week");

for (const u of [u1, u2, u3]) await fetch(`${API}/auth/v1/admin/users/${u.id}`, { method: "DELETE", headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } });
sql(`delete from private.free_week_logins where sunsynk_username = 'solo@mock'`);
console.log(fail ? `${fail} FAILED` : "PASS");
process.exit(fail ? 1 : 0);
