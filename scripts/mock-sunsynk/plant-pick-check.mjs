#!/usr/bin/env node
// The plant pick (SOLAR-537, 0197) through the real link-sunsynk and the RPCs: a login's
// plants link locked, the owner ticks up to the plan's number, one change per 90 days
// (the plant out loses its readings), a second change is refused with its date, a cancel
// and a new payment bring the same plants back, and a removed login linked again gives no
// fresh pick. Local stack with the mock SunSynk server only. Exit code decides.
//
//   eval "$(supabase status -o env | grep -E '^(API_URL|SERVICE_ROLE_KEY|ANON_KEY)=')"
//   node scripts/mock-sunsynk/plant-pick-check.mjs
// PSQL names a psql to use (default: psql on the PATH), called as `PSQL <db-url> -XAtc <sql>`.
import { execFileSync } from "node:child_process";
const API = (process.env.API_URL || "http://127.0.0.1:55321").replace(/"/g, "");
const FN = process.env.LINK_URL || `${API}/functions/v1/link-sunsynk`;
const SERVICE = (process.env.SERVICE_ROLE_KEY || "").replace(/"/g, ""), ANON = (process.env.ANON_KEY || "").replace(/"/g, "");
const DB = process.env.DB_URL?.replace(/"/g, "") || "postgresql://postgres:postgres@127.0.0.1:55322/postgres";
// The local DB is shared: another session's billing run can deadlock a write here. Try again.
const sql = (q) => { for (let t = 1; ; t++) try { return execFileSync(process.env.PSQL || "psql", [DB, "-XAtc", q], { stdio: ["ignore", "pipe", "pipe"] }).toString().trim(); }
  catch (e) { if (t >= 5 || !/deadlock detected/.test(String(e.stderr))) throw e; } };
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

const u = await user("home");
sql(`insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values ('${u.id}', 'home', 'monthly', extract(day from current_date + 15)::int, current_date + 15)`);
const status = async () => (await rpc(u, "api_link_status", {})).body.flatMap((a) => a.plants);
console.log("Home user, one login with several plants");
let r = await link(u, "installer@mock");
const all = stopped(u).split(",").filter(Boolean).map(Number);
check(r.status === 200 && active(u) === "" && all.length >= 3 && r.body.paused.length === all.length, `every plant links locked: ${r.status} locked=${all}`);
check((await status()).every((p) => p.can_start), "each one has a place open");
const [a, b, c] = all;
// The mock plants are shared with the seed users. A plant someone else collects keeps
// its readings, so their rows on these plants are locked for this run, and put back after.
// Taking a out deletes its local readings: the local seed loses that plant's history.
const others = sql(`select coalesce(string_agg(user_id || ':' || plant_id, ','), '') from public.plant_users
                     where plant_id in (${a}, ${b}, ${c}) and user_id <> '${u.id}' and not paused`).split(",").filter(Boolean);
sql(`update public.plant_users set paused = true where plant_id in (${a}, ${b}, ${c}) and user_id <> '${u.id}'`);
const restore = () => others.splice(0).forEach(x => { const [uid, pid] = x.split(":"); sql(`update public.plant_users set paused = false where user_id = '${uid}' and plant_id = ${pid}`); });
const changedOn = () => sql(`select coalesce((select changed_on::text from private.plant_change where user_id = '${u.id}'), '')`);

try {
r = await rpc(u, "api_plant_pick", { p_plants: [a, b, c] });
check(!r.ok && /no room/.test(r.error) && active(u) === "", `3 ticks on Home are refused, none ticked: ${r.error}`);
r = await rpc(u, "api_plant_pick", { p_plants: [a, b] });
check(r.ok && active(u) === `${a},${b}`, `2 ticked run: ${r.error || "ok"} on=${active(u)}`);
check(sql(`select backfill_next = (now() at time zone coalesce(timezone, 'Africa/Johannesburg'))::date - 60 from public.plant_config where plant_id = ${a}`) === "t",
  "a ticked plant's history goes back 60 days");
r = await rpc(u, "api_plant_pick", { p_plants: [c] });
check(!r.ok && /no room/.test(r.error), `a third tick is refused: ${r.error}`);
check((await status()).every((p) => !p.can_start), "the locked plant has no place open");

console.log("One change, then 90 days");
sql(`insert into public.plant_energy (plant_id, bucket, period, pv_kwh) values (${a}, 'day', current_date - 1, 1) on conflict do nothing`);
check(energyRows(a) > 0, "the plant going out has readings");
r = await rpc(u, "api_plant_change", { p_out: a, p_in: c });
check(r.ok && active(u) === `${b},${c}`, `the first change is ready at once: ${r.error || "ok"} on=${active(u)}`);
sql(`call private.plant_wipes()`); // the plant-wipe cron job; pg_cron is off locally
check(energyRows(a) === 0, "the plant taken out loses its readings");
sql(`insert into public.plant_energy (plant_id, bucket, period, pv_kwh) values (${a}, 'day', current_date - 2, 1) on conflict do nothing`);
check(energyRows(a) === 0, "a late write for a locked plant is dropped");
const opens = sql(`select ((now() at time zone 'Africa/Johannesburg')::date + 90)::text`);
r = await rpc(u, "api_plant_change", { p_out: b, p_in: a });
check(!r.ok && r.error === `next change ${opens}` && active(u) === `${b},${c}`, `a second change is refused with the date it opens: ${r.error}`);
check((await rpc(u, "api_plant_picks", {})).body.change_on === opens, "the screen's date is the same");
const changed = changedOn();

console.log("Cancel, then pay again");
r = await rpc(u, "api_billing_change", { p_plan: "free", p_period: null, p_keep: [b] });
check(r.ok, `cancel booked, keeping one: ${r.error || "ok"}`);
sql(`update private.billing set next_billing_date = (now() at time zone 'Africa/Johannesburg')::date where user_id = '${u.id}'; select public.billing_renew('${u.id}')`);
check(active(u) === String(b) && !stopped(u).split(",").includes(String(c)), `on Free one plant runs, the other is deleted: on=${active(u)} locked=${stopped(u)}`);
r = await link(u, "installer@mock"); // lists the deleted plant again
r = await rpc(u, "api_plant_pick", { p_plants: [c] });
check(!r.ok && /no room/.test(r.error), `Free has no place for it: ${r.error}`);
const ref = sql(`select public.billing_charge_open('${u.id}', 'home', 'monthly')->>'reference'`);
sql(`select public.billing_charge_paid('${ref}', null, true, null)`);
check(active(u) === `${b},${c}`, `paying Home again brings the same two back: on=${active(u)}`);
check(changedOn() === changed, "the change was not used");

console.log("Remove the login, link it again");
const acc = sql(`select id from private.sunsynk_accounts where user_id = '${u.id}'`);
r = await rpc(u, "api_link_remove", { p_account: acc });
check(r.ok && active(u) === "" && stopped(u) === "", `login removed, its plants gone: ${r.error || "ok"}`);
r = await link(u, "installer@mock");
check(r.status === 200 && active(u) === `${b},${c}`, `the two ticked plants start on their own: on=${active(u)}`);
r = await rpc(u, "api_plant_pick", { p_plants: [a] });
check(!r.ok && /no room/.test(r.error), `no fresh pick: ${r.error}`);
r = await rpc(u, "api_plant_change", { p_out: b, p_in: a });
check(!r.ok && /next change/.test(r.error), `and the change is still closed: ${r.error}`);

} finally { restore(); } // seed users' plants run again even when a step throws
await fetch(`${API}/auth/v1/admin/users/${u.id}`, { method: "DELETE", headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } });
sql(`delete from private.free_week_logins where sunsynk_username = 'installer@mock'`);
console.log(fail ? `${fail} FAILED` : "PASS");
process.exit(fail ? 1 : 0);
