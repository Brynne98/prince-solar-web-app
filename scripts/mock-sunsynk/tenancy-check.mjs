#!/usr/bin/env node
// Tenancy check across the seeded users: each sees its own plants and nothing
// else, through the same RPCs the browser uses. Exit code decides.
//
//   eval "$(supabase status -o env | grep -E '^(API_URL|ANON_KEY)=')"; node scripts/mock-sunsynk/tenancy-check.mjs
const API = (process.env.API_URL || "http://127.0.0.1:55321").replace(/"/g, "");
const ANON = (process.env.ANON_KEY || "").replace(/"/g, "");
const PASSWORD = "devpassword123";
const EXPECT = {
  "dev@local.test":    [3001, 5001, 6002, 6003, 6004],
  "family@local.test": [5001],
  "export@local.test": [3001, 6002],
  "nobatt@local.test": [6003],
  "shared@local.test": [6004],
};
const ALL = [...new Set(Object.values(EXPECT).flat())];
let failures = 0;
const check = (ok, what) => { console.log((ok ? "  ok   " : "  FAIL ") + what); if (!ok) failures++; };

async function session(email) {
  const r = await (await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" }, body: JSON.stringify({ email, password: PASSWORD }),
  })).json();
  if (!r.access_token) throw new Error(`sign-in ${email}: ${JSON.stringify(r)}`);
  return r.access_token;
}
async function rpc(jwt, fn, args = {}) {
  const res = await fetch(`${API}/rest/v1/rpc/${fn}`, {
    method: "POST", headers: { apikey: ANON, Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" }, body: JSON.stringify(args),
  });
  const body = await res.json().catch(() => null);
  return { status: res.status, body };
}
async function rest(jwt, path) {
  const res = await fetch(`${API}/rest/v1/${path}`, { headers: { apikey: ANON, Authorization: `Bearer ${jwt}` } });
  return { status: res.status, body: await res.json().catch(() => null) };
}

for (const [email, plants] of Object.entries(EXPECT)) {
  console.log(email);
  const jwt = await session(email);
  const me = await rpc(jwt, "api_me");
  const mine = ((me.body && me.body.plants) || []).map((p) => p.id).sort();
  check(JSON.stringify(mine) === JSON.stringify([...plants].sort()), `api_me plants = ${mine.join(",")}`);
  for (const pid of plants) {
    const ov = await rpc(jwt, "api_overview", { p_plant: pid });
    check(ov.status === 200 && ov.body && ov.body.plant && Number(ov.body.plant.id) === pid, `api_overview(${pid}) -> own plant`);
    const hist = await rpc(jwt, "api_history", { p_plant: pid, p_date: null });
    check(hist.status === 200, `api_history(${pid})`);
  }
  for (const pid of ALL.filter((p) => !plants.includes(p))) {
    const ov = await rpc(jwt, "api_overview", { p_plant: pid });
    check(ov.status >= 400, `api_overview(${pid}) refused (${ov.status})`);
    const bal = await rpc(jwt, "api_balance", { p_plant: pid });
    check(bal.status >= 400, `api_balance(${pid}) refused (${bal.status})`);
  }
  const cfg = await rest(jwt, "plant_config?select=plant_id");
  const cfgIds = (cfg.body || []).map((r) => Number(r.plant_id)).sort();
  check(JSON.stringify(cfgIds) === JSON.stringify([...plants].sort()), `plant_config rows = ${cfgIds.join(",")}`);
  const agg = await rest(jwt, "agg_minute?select=plant_id&limit=1000");
  const aggIds = [...new Set((agg.body || []).map((r) => Number(r.plant_id)))].sort();
  check(aggIds.every((id) => plants.includes(id)), `agg_minute plants = ${aggIds.join(",")}`);
  const alerts = await rpc(jwt, "api_alerts_due", { p_plant: plants[0] });
  check(alerts.status >= 400, `api_alerts_due not callable by a user (${alerts.status})`);
  const link = await rpc(jwt, "api_link_status");
  const accs = (link.body || []).map((a) => a.sunsynk_username);
  check(link.status === 200 && accs.length > 0, `api_link_status -> ${accs.join(",")}`);
}
console.log(failures ? `\n${failures} FAILED` : "\nALL PASS");
process.exit(failures ? 1 : 0);
