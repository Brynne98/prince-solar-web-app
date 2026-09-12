#!/usr/bin/env node
// Settings round-trips as a signed-in user: the plant_config triggers that keep
// batt_sign_source / features_source honest, and the client_errors insert path.
//   eval "$(supabase status -o env | grep -E '^(API_URL|ANON_KEY)=')"; node scripts/mock-sunsynk/settings-check.mjs
const API = (process.env.API_URL || "http://127.0.0.1:55321").replace(/"/g, "");
const ANON = (process.env.ANON_KEY || "").replace(/"/g, "");
let failures = 0;
const check = (ok, what) => { console.log((ok ? "  ok   " : "  FAIL ") + what); if (!ok) failures++; };
async function session(email) {
  const r = await (await fetch(`${API}/auth/v1/token?grant_type=password`, { method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" }, body: JSON.stringify({ email, password: "devpassword123" }) })).json();
  if (!r.access_token) throw new Error(`sign-in ${email}`);
  return r;
}
const h = (jwt, extra = {}) => ({ apikey: ANON, Authorization: `Bearer ${jwt}`, "Content-Type": "application/json", Prefer: "return=representation", ...extra });
async function patch(jwt, plant, body) {
  const res = await fetch(`${API}/rest/v1/plant_config?plant_id=eq.${plant}`, { method: "PATCH", headers: h(jwt), body: JSON.stringify(body) });
  const rows = await res.json().catch(() => null);
  return { status: res.status, row: Array.isArray(rows) ? rows[0] : null };
}

const s = await session("shared@local.test");
const jwt = s.access_token;
console.log("shared@local.test on plant 6004");
let r = await patch(jwt, 6004, { battery_banks: "shared", tariff_export: 1.25 });
check(r.status === 200 && r.row?.battery_banks === "shared" && Number(r.row?.tariff_export) === 1.25, `battery_banks=shared, tariff_export=1.25 (${r.status})`);
r = await patch(jwt, 6004, { batt_positive_means: "charging" });
check(r.row?.batt_sign_source === "user", `manual battery sign -> source=user (${r.row?.batt_sign_source})`);
r = await patch(jwt, 6004, { batt_positive_means: null });
check(r.row?.batt_sign_source === "default" && r.row?.batt_positive_means == null, `Auto -> source=default, value cleared`);
r = await patch(jwt, 6004, { has_battery: true, has_grid: true });
check(r.row?.features_source === "user", `equipment set by hand -> features_source=user`);
r = await patch(jwt, 6004, { has_battery: null, has_grid: null });
check(r.row?.features_source === "default", `equipment back to auto -> features_source=default`);
r = await patch(jwt, 6004, { plan: "pro" });
check(r.status >= 400 || r.row?.plan === undefined, `unknown column refused (${r.status})`);
// another user's plant: RLS makes the update a no-op
r = await patch(jwt, 5001, { tariff_import: 99 });
check(r.status === 200 && r.row == null, `update on 5001 touches nothing (${r.status})`);
// client_errors: own row inserts, someone else's user_id refused
let res = await fetch(`${API}/rest/v1/client_errors`, { method: "POST", headers: h(jwt, { Prefer: "return=minimal" }), body: JSON.stringify({ user_id: s.user.id, message: "settings-check test error", app_version: "test" }) });
check(res.status === 201, `client_errors insert as self (${res.status})`);
res = await fetch(`${API}/rest/v1/client_errors`, { method: "POST", headers: h(jwt, { Prefer: "return=minimal" }), body: JSON.stringify({ user_id: "00000000-0000-0000-0000-000000000001", message: "spoof" }) });
check(res.status >= 400, `client_errors insert as someone else refused (${res.status})`);
res = await fetch(`${API}/rest/v1/client_errors?select=id`, { headers: h(jwt) });
check(res.status >= 400 || (await res.json()).length === 0, `client_errors not readable by a user`);
console.log(failures ? `\n${failures} FAILED` : "\nALL PASS");
process.exit(failures ? 1 : 0);
