#!/usr/bin/env node
// Stop and start plants (SOLAR-251) through the real link-sunsynk and the RPCs: a full
// plan refuses a start, a stop deletes the plant's readings, a start sets the history
// bookmarks, a cancel waits until the plants fit. Local stack with the mock SunSynk
// server only. Exit code decides.
//
//   eval "$(supabase status -o env | grep -E '^(API_URL|SERVICE_ROLE_KEY|ANON_KEY)=')"
//   node scripts/mock-sunsynk/plant-pick-check.mjs
// PSQL names a psql to use (default: psql on the PATH), called as `PSQL <db-url> -XAtc <sql>`.
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
  const email = `${name}-${tag}@pick.test`;
  const h = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json" };
  const u = await (await fetch(`${API}/auth/v1/admin/users`, { method: "POST", headers: h, body: JSON.stringify({ email, password: "devpassword123", email_confirm: true }) })).json();
  const s = await (await fetch(`${API}/auth/v1/token?grant_type=password`, { method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" }, body: JSON.stringify({ email, password: "devpassword123" }) })).json();
  return { id: u.id, jwt: s.access_token };
}
async function link(u, username) {
  const r = await fetch(FN, { method: "POST", headers: { apikey: ANON, Authorization: `Bearer ${u.jwt}`, "Content-Type": "application/json" }, body: JSON.stringify({ username, password: "x" }) });
  return { status: r.status, body: await r.json().catch(() => null) };
}
async function rpc(u, fn, args) {
  const r = await fetch(`${API}/rest/v1/rpc/${fn}`, { method: "POST", headers: { apikey: ANON, Authorization: `Bearer ${u.jwt}`, "Content-Type": "application/json" }, body: JSON.stringify(args) });
  const body = await r.json().catch(() => null);
  return { ok: r.ok, body, error: r.ok ? null : (body?.message || String(r.status)) };
}
const active = (u) => sql(`select coalesce(string_agg(plant_id::text, ',' order by plant_id), '') from public.plant_users where user_id = '${u.id}' and not paused`);
const stopped = (u) => sql(`select coalesce(string_agg(plant_id::text, ',' order by plant_id), '') from public.plant_users where user_id = '${u.id}' and paused`);
const energyRows = (p) => Number(sql(`select count(*) from public.plant_energy where plant_id = ${p}`));

const u = await user("free");
console.log("Free user, one login with several plants");
let r = await link(u, "installer@mock");
const on = active(u).split(",").filter(Boolean), off = stopped(u).split(",").filter(Boolean);
check(r.status === 200 && on.length === 1 && off.length >= 1, `one plant collects, the rest stopped: ${r.status} on=${on} off=${off}`);
const [a] = on.map(Number), [b] = off.map(Number);
// The mock plants are shared with the seed users. A plant someone else collects keeps
// its readings, so their rows on a and b are stopped for this run, and put back after.
// Stopping a deletes its local readings: the local seed loses that plant's history.
const others = sql(`select coalesce(string_agg(user_id || ':' || plant_id, ','), '') from public.plant_users
                     where plant_id in (${a}, ${b}) and user_id <> '${u.id}' and not paused`).split(",").filter(Boolean);
sql(`update public.plant_users set paused = true where plant_id in (${a}, ${b}) and user_id <> '${u.id}'`);
const restore = () => others.forEach(x => { const [uid, pid] = x.split(":"); sql(`update public.plant_users set paused = false where user_id = '${uid}' and plant_id = ${pid}`); });

r = await rpc(u, "api_plant_start", { p_plant: b });
check(!r.ok && /no room/.test(r.error), `start on a full plan is refused: ${r.error}`);

sql(`insert into public.plant_energy (plant_id, bucket, period, pv_kwh) values (${a}, 'day', current_date - 1, 1) on conflict do nothing`);
check(energyRows(a) > 0, "the collecting plant has readings");
r = await rpc(u, "api_plant_stop", { p_plant: a });
check(r.ok && energyRows(a) > 0, "the delete waits for the cron run");
sql(`call private.plant_wipes()`); // the plant-wipe cron job; pg_cron is off locally
check(r.ok && energyRows(a) === 0 && stopped(u).split(",").includes(String(a)), `stop deletes its readings: ${JSON.stringify(r.body)}`);
sql(`insert into public.plant_energy (plant_id, bucket, period, pv_kwh) values (${a}, 'day', current_date - 2, 1) on conflict do nothing`);
check(energyRows(a) === 0, "a late write for a stopped plant is dropped");

r = await rpc(u, "api_plant_start", { p_plant: b });
check(r.ok && active(u) === String(b), `start the other one: ${r.error || "ok"} on=${active(u)}`);
check(sql(`select backfill_next = (now() at time zone coalesce(timezone, 'Africa/Johannesburg'))::date - 60 from public.plant_config where plant_id = ${b}`) === "t",
  "in the free week, history goes back 60 days");
r = await rpc(u, "api_plant_stop", { p_plant: a });
check(r.ok, "stopping a stopped plant is a no-op");

console.log("Paid plan cancel");
const nd = sql(`select (current_date + 15)::date`);
sql(`insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values ('${u.id}', 'family', 'monthly', extract(day from current_date + 15)::int, '${nd}')`);
r = await rpc(u, "api_plant_start", { p_plant: a });
check(r.ok && active(u).split(",").length === 2, `Family has room for a 2nd: ${r.error || "ok"}`);
r = await rpc(u, "api_billing_change", { p_plan: "free", p_period: null });
check(!r.ok && /remove plants first/.test(r.error), `cancel with 2 collecting is refused: ${r.error}`);
r = await rpc(u, "api_plant_stop", { p_plant: a });
r = await rpc(u, "api_billing_change", { p_plan: "free", p_period: null });
check(r.ok, `after a stop the cancel goes through: ${r.error || "ok"}`);
r = await rpc(u, "api_plant_start", { p_plant: a });
check(!r.ok && /plan change/.test(r.error), `a start that breaks the booked cancel is refused: ${r.error}`);

restore();
await fetch(`${API}/auth/v1/admin/users/${u.id}`, { method: "DELETE", headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } });
sql(`delete from private.free_week_logins where sunsynk_username = 'installer@mock'`);
console.log(fail ? `${fail} FAILED` : "PASS");
process.exit(fail ? 1 : 0);
