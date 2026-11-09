#!/usr/bin/env node
// Attacker's test of billing and plant limits (SOLAR-264). LOCAL stack only.
//
//   node scripts/billing-sim/abuse.mjs            # all attacks
//   node scripts/billing-sim/abuse.mjs G6 M3      # only ids starting with these
//   node scripts/billing-sim/abuse.mjs --seed 3   # the C (many requests at once) attacks in seed 3's order
//
// Exit 0: every attack failed. Exit 1: at least one attack worked (a bug).
// Exit 2: the harness broke. "design" attacks work on purpose (decided rules);
// they are printed but do not change the exit code.
//
// Makes its own users atk-<n>-<run>@sim.test, signs in as them, and removes every
// user and row at the end. Needs the local stack, and the mock SunSynk server on
// :4400 (started here if it is not running). Never reads or prints keys.
import { execFileSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const env = Object.fromEntries(
  execFileSync("supabase", ["status", "-o", "env"], { cwd: REPO }).toString().split("\n")
    .map((l) => l.match(/^([A-Z_]+)="?(.*?)"?$/)).filter(Boolean).map((m) => [m[1], m[2]]));
const API = env.API_URL, ANON = env.ANON_KEY, SERVICE = env.SERVICE_ROLE_KEY;
const DB = env.DB_URL || "postgresql://postgres:postgres@127.0.0.1:55322/postgres";
if (!/^https?:\/\/(127\.0\.0\.1|localhost)/.test(API) || !/(127\.0\.0\.1|localhost)/.test(DB)) {
  console.error("refusing to run: this is not the local stack"); process.exit(2);
}
const PSQL = process.env.PSQL || "/opt/homebrew/opt/libpq/bin/psql";
const FN = `${API}/functions/v1`;
const ORIGIN = "http://localhost:3003";
const RUN = String(Date.now()).slice(-6);
const argv = process.argv.slice(2);
const si = argv.indexOf("--seed");
const SEED = si < 0 ? 1 : Number(argv[si + 1]);
const only = argv.filter((a, i) => a !== "--seed" && (si < 0 || i !== si + 1));
// seeded shuffle for the C attacks: each seed fires the same requests in another order
let rs = (SEED * 2654435761) >>> 0;
const rnd = () => { rs = (rs + 0x6D2B79F5) >>> 0; let t = Math.imul(rs ^ (rs >>> 15), 1 | rs); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
const shuffle = (xs) => { const a = xs.slice(); for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; } return a; };

const sql = (q) => execFileSync(PSQL, [DB, "-XAtq", "-v", "ON_ERROR_STOP=1", "-c", q], { stdio: ["ignore", "pipe", "pipe"] }).toString().trim();
const num = (q) => Number(sql(q));

async function http(method, url, { jwt, key, body, headers = {} } = {}) {
  const r = await fetch(url, {
    method,
    headers: { apikey: key || ANON, Authorization: `Bearer ${jwt || key || ANON}`, "Content-Type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  let data = text; try { data = JSON.parse(text); } catch { /* keep text */ }
  return { status: r.status, data };
}
const rpc = (u, fn, args = {}) => http("POST", `${API}/rest/v1/rpc/${fn}`, { jwt: u?.jwt, body: args });
const svc = (fn, args = {}) => http("POST", `${API}/rest/v1/rpc/${fn}`, { key: SERVICE, body: args });
const rest = (u, method, p, body, headers = {}) =>
  http(method, `${API}/rest/v1/${p}`, { jwt: u?.jwt, body, headers: { Prefer: "return=representation", ...headers } });
const good = (r) => r.status >= 200 && r.status < 300;
const rows = (r) => (Array.isArray(r.data) ? r.data.length : good(r) && r.data ? 1 : 0);

// ---------------------------------------------------------------- users
const USERS = []; let seq = 0;
async function user(label) {
  const email = `atk-${++seq}-${RUN}@sim.test`, password = "atk-pass-" + RUN + "-xyz";
  const c = await http("POST", `${API}/auth/v1/admin/users`, { key: SERVICE, body: { email, password, email_confirm: true } });
  if (!c.data?.id) throw new Error(`create user failed: ${c.status}`);
  const s = await http("POST", `${API}/auth/v1/token?grant_type=password`, { body: { email, password } });
  if (!s.data?.access_token) throw new Error("sign-in failed");
  const u = { id: c.data.id, email, jwt: s.data.access_token, label };
  USERS.push(u); return u;
}
async function link(u, login, extra = {}) {
  sql(`delete from private.link_attempts where user_id = '${u.id}'`);
  const r = await http("POST", `${FN}/link-sunsynk`, { jwt: u.jwt, headers: { Origin: ORIGIN }, body: { username: login, password: "x", ...extra } });
  return r;
}
/** Stand-in for a Paystack payment: open the charge the way /billing/pay does, then settle it. */
async function pay(u, body = {}) {
  const o = await svc("billing_charge_open", {
    p_user: u.id, p_plan: String(body.plan ?? ""), p_period: body.period ? String(body.period) : null,
    p_extra: Number.isSafeInteger(body.extras) ? body.extras : null,
  });
  if (!good(o)) return { err: o.data?.message || o.status };
  if (o.data.amount > 0) {
    const p = await svc("billing_charge_paid", { p_reference: o.data.reference, p_card: null, p_quiet: true, p_cents: o.data.amount * 100 });
    if (!good(p)) return { err: p.data?.message || p.status };
  }
  return o.data;
}
// A plan's price at the offer a charge was opened with (0145: the launch offer charges less).
const priceAt = (ref, plan, period, extras = 0) => num(`select public.billing_amount('${plan}', '${period}', ${extras},
  (select offer_id from private.billing_charges where reference = '${ref}'))`);
const active = (u) => num(`select count(*) from public.plant_users where user_id='${u.id}' and not paused`);
const planOf = (u) => sql(`select coalesce((select plan from private.billing where user_id='${u.id}'),'free')`);
const family = async (label) => { const u = await user(label); const p = await pay(u, { plan: "family", period: "monthly" }); if (p.err) throw new Error(p.err); return u; };
// 0156: extras are no longer sold; an account that still holds some gets them set here, as regress.mjs does.
const holdExtras = (u, n) => sql(`update private.billing set extra_plants = ${n} where user_id='${u.id}'`);
const home = async (label) => { const u = await user(label); const p = await pay(u, { plan: "home", period: "monthly" }); if (p.err) throw new Error(p.err); return u; };

// ---------------------------------------------------------------- runner
const RESULTS = []; let broken = 0;
async function attack(id, title, fn, { design = false } = {}) {
  if (only.length && !only.some((p) => id.startsWith(p))) return;
  try {
    const r = await fn();
    RESULTS.push({ id, title, hit: !!r.hit, design, note: r.note || "" });
    console.log(`${r.hit ? (design ? "[DESIGN]" : "[HIT]   ") : "[safe]  "} ${id} ${title}${r.note ? " -- " + r.note : ""}`);
  } catch (e) {
    broken++; RESULTS.push({ id, title, error: String(e.message || e) });
    console.log(`[ERROR] ${id} ${title} -- ${String(e.message || e).split("\n")[0]}`);
  }
}

// ------------------------------------------------------------------- run
let mockStarted = null;
async function ensureMock() {
  try { await fetch("http://127.0.0.1:4400/"); return; } catch { /* start it */ }
  mockStarted = spawn("node", [path.join(REPO, "scripts/mock-sunsynk/server.js")], { stdio: "ignore", detached: false });
  for (let i = 0; i < 30; i++) { try { await fetch("http://127.0.0.1:4400/"); return; } catch { await new Promise((r) => setTimeout(r, 200)); } }
  throw new Error("mock SunSynk did not start");
}

async function cleanup() {
  const ids = USERS.map((u) => `'${u.id}'`).join(",");
  if (!USERS.length) return "nothing to clean";
  for (const u of USERS) { try { await rpc(u, "api_account_delete"); } catch { /* admin delete below */ } }
  for (const u of USERS) await http("DELETE", `${API}/auth/v1/admin/users/${u.id}`, { key: SERVICE });
  const emails = USERS.map((u) => `'${u.email}'`).join(",");
  sql(`delete from public.email_queue where user_id in (${ids}) or to_email in (${emails})`);
  const tables = sql(`select table_schema||'.'||table_name from information_schema.columns where column_name='user_id' and table_schema in ('public','private')
                       and table_name in (select tablename from pg_tables where schemaname in ('public','private'))`).split("\n");
  let left = 0;
  for (const t of tables) {
    const n = num(`select count(*) from ${t} where user_id in (${ids})`);
    if (n) { try { sql(`delete from ${t} where user_id in (${ids})`); } catch { /* counted below */ } left += num(`select count(*) from ${t} where user_id in (${ids})`); }
  }
  left += num(`select count(*) from auth.users where id in (${ids})`);
  sql(`delete from public.plant_users where plant_id between 9264000 and 9264999`);
  sql(`delete from public.plant_config where plant_id between 9264000 and 9264999`);
  return left === 0 ? `removed ${USERS.length} users and their rows` : `${left} rows left`;
}


try {
await ensureMock();
// =================================================================== G1 inventory
const ALLOW_AUTH = new Set(`_energy_row _erow _hm _plant_day_energy admin_overview api_account_delete api_alerts api_balance api_billing_change
api_billing_extras api_billing_keep api_billing_quote api_billing_status billing_room api_data_days api_db_stats api_energy api_export api_grid_off_recent api_grid_today api_health
api_history api_history_earliest api_inverter_history api_link_disconnect api_link_remove api_link_status api_me api_notifications
api_notifications_read api_offer api_overview api_plant_days api_plant_start api_plant_states api_plant_stop api_prefs_set api_push_sub
api_push_unsub api_string_health api_trends_by_hour api_trends_compare api_trends_daily calibration_plant cfg client_errors_cap
battery_groups_kwh day_start_epoch day_start_epoch_tz email_prefs_touch handle_new_user local_day local_day_tz local_hour local_hour_tz local_minute
local_minute_tz local_ts local_ts_tz my_plant my_plant_ids panel_kwp plant_cfg plant_config_batt_sign_guard plant_config_features_guard
plant_config_touch plant_tz profiles_guard q_by_hour q_day_agg q_day_gap_minutes q_grid_present q_recovered_minutes q_stats today_tz`.split(/\s+/));
// api_offer: the website reads prices and the offer before sign-in (0145).
const ALLOW_ANON = new Set("api_health api_offer client_errors_cap email_prefs_touch handle_new_user local_day local_hour my_plant_ids panel_kwp plant_config_batt_sign_guard plant_config_features_guard plant_config_touch profiles_guard".split(" "));
const SERVICE_ONLY = ["billing_charge_open", "billing_charge_paid", "billing_charge_failed", "billing_charge_refunded", "billing_run", "billing_renew",
  "billing_set_comped", "billing_charge_disputed", "billing_refunds_due", "billing_charge_refund_event", "billing_book_change", "billing_book_removal", "billing_free_week_start", "billing_may_link", "billing_upgrade_quote",
  "billing_amount_due", "billing_settle_open", "billing_card_open", "plant_users_upsert", "account_upsert",
  "inverters_seed", "plant_config_seed", "link_attempt", "free_trimmed_plants", "accounts_active", "poll_jobs", "plant_bootstrap_kick",
  "billing_charge_user"];

await attack("G1a", "authenticated can run only the known functions", async () => {
  const names = sql(`select p.proname from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f' and has_function_privilege('authenticated',p.oid,'execute')`).split("\n");
  const extra = names.filter((n) => !ALLOW_AUTH.has(n));
  return { hit: extra.length > 0, note: extra.join(",") };
});
await attack("G1b", "anon can run only the known functions", async () => {
  const names = sql(`select p.proname from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f' and has_function_privilege('anon',p.oid,'execute')`).split("\n");
  const extra = names.filter((n) => !ALLOW_ANON.has(n));
  return { hit: extra.length > 0, note: extra.join(",") };
});
await attack("G1c", "private schema and its tables are closed to users", async () => {
  const usage = sql(`select has_schema_privilege('authenticated','private','usage') or has_schema_privilege('anon','private','usage')`) === "t";
  const t = sql(`select count(*) from information_schema.role_table_grants where grantee in ('anon','authenticated') and table_schema='private'`);
  const rls = sql(`select string_agg(tablename,',') from pg_tables where schemaname='public' and not rowsecurity`);
  return { hit: usage || t !== "0" || !!rls, note: rls ? "no RLS: " + rls : "" };
});
await attack("G1d", "service-only functions are not callable by a user or anon", async () => {
  const a = await user("g1d"); const bad = [];
  const args = { p_user: a.id, p_plan: "family", p_period: "monthly", p_reference: "x", p_plants: [1], p_paused: false, p_plant: 1, p_error: "x",
    p_account: a.id, p_rows: [], p_sunsynk_username: "x", p_plant_inverters: [1], p_today: null, p_added: 0, p_extra: 0, p_shard: 0, p_shards: 1 };
  for (const f of SERVICE_ONLY) for (const who of [a, null]) {
    const r = await rpc(who, f, args);
    if (good(r) || (r.status === 400 && !/permission|denied|schema cache/i.test(JSON.stringify(r.data)))) bad.push(f + (who ? "" : "(anon)") + ":" + r.status);
  }
  return { hit: bad.length > 0, note: bad.join(",") };
});
await attack("G1e", "private schema over REST is refused (billing, charges, free week)", async () => {
  const a = await user("g1e"); const bad = [];
  for (const t of ["billing", "billing_charges", "free_week_logins", "sunsynk_accounts", "link_attempts", "admins"]) {
    for (const [m, body] of [["GET"], ["PATCH", { plan: "family" }], ["POST", { user_id: a.id }]]) {
      const r = await http(m, `${API}/rest/v1/${t}${m === "PATCH" ? "?user_id=eq." + a.id : ""}`, { jwt: a.jwt, body, headers: { "Accept-Profile": "private", "Content-Profile": "private", Prefer: "return=representation" } });
      if (good(r)) bad.push(`${m} ${t}`);
    }
  }
  return { hit: bad.length > 0, note: bad.join(",") };
});

// =================================================================== G2 direct writes
await attack("G2a", "REST writes on plant_users, billing fields, other users' rows", async () => {
  const a = await user("g2a"); const v = await user("g2v");
  await link(a, "installer@mock"); await link(v, "solo@mock");           // a: 1 active + 4 paused
  const bad = []; const pausedBefore = num(`select count(*) from public.plant_users where user_id='${a.id}' and paused`);
  const t = async (name, r) => { if (rows(r) > 0) bad.push(`${name}:${r.status}`); };
  await t("unpause own", await rest(a, "PATCH", `plant_users?user_id=eq.${a.id}&paused=eq.true`, { paused: false }));
  await t("unpause as other user's row", await rest(a, "PATCH", `plant_users?user_id=eq.${v.id}`, { paused: false }));
  await t("insert plant for self", await rest(a, "POST", "plant_users", { user_id: a.id, plant_id: 987001, plant_name: "x" }));
  await t("insert plant for other user", await rest(a, "POST", "plant_users", { user_id: v.id, plant_id: 987002, plant_name: "x" }));
  await t("move linked_at", await rest(a, "PATCH", `plant_users?user_id=eq.${a.id}`, { linked_at: "2000-01-01" }));
  await t("delete own row", await rest(a, "DELETE", `plant_users?user_id=eq.${a.id}`));
  await t("profiles.plan", await rest(a, "PATCH", `profiles?user_id=eq.${a.id}`, { plan: "family" }));
  await t("profiles comped", await rest(a, "PATCH", `profiles?user_id=eq.${a.id}`, { comped: true }));
  await t("profile of other user", await rest(a, "PATCH", `profiles?user_id=eq.${v.id}`, { prefs: { x: 1 } }));
  await t("profile insert for other", await rest(a, "POST", "profiles", { user_id: v.id, prefs: {} }));
  await t("email_prefs other", await rest(a, "PATCH", `email_prefs?user_id=eq.${v.id}`, { weekly: false }));
  await t("push_prefs other", await rest(a, "PATCH", `push_prefs?user_id=eq.${v.id}`, { grid: false }));
  await t("client_errors as other", await rest(a, "POST", "client_errors", { user_id: v.id, message: "x", page: "x" }));
  await t("app_config write", await rest(a, "PATCH", "app_config?key=eq.LAT", { value: 0 }));
  await t("email_queue read", await rest(a, "GET", "email_queue"));
  const after = num(`select count(*) from public.plant_users where user_id='${a.id}' and paused`);
  if (after !== pausedBefore) bad.push("paused count changed");
  if (planOf(a) !== "free") bad.push("plan changed");
  return { hit: bad.length > 0, note: bad.join("; ") };
});
await attack("G2b", "plant_config of a plant I do not collect (not mine, or stopped)", async () => {
  const a = await user("g2b"); const bad = [];
  const r1 = await rest(a, "PATCH", "plant_config?plant_id=eq.6004", { backfill_tries: 0 });   // not linked
  if (rows(r1) > 0) bad.push("unlinked plant");
  await link(a, "installer@mock");                       // 6004 comes in paused
  const r2 = await rest(a, "PATCH", "plant_config?plant_id=eq.6004", { backfill_tries: 0 });
  if (rows(r2) > 0) bad.push("own paused plant");
  const r3 = await rest(a, "GET", "plant_config?plant_id=eq.6004");
  if (rows(r3) > 0) bad.push("read paused plant config");
  return { hit: bad.length > 0, note: bad.join("; ") };
});
await attack("G2c", "co-owner edits shared plant settings and history pointers (same value written)", async () => {
  const a = await user("g2c"); await link(a, "solo@mock");           // 6003, shared with nobatt@local.test
  const cur = sql("select backfill_tries from public.plant_config where plant_id=6003");
  const r = await rest(a, "PATCH", "plant_config?plant_id=eq.6003", { backfill_tries: Number(cur || 0), backfill_next: null });
  return { hit: rows(r) > 0, note: "any user linked to a plant can write backfill_*/temp_* and settings; recover skips free-trimmed plants" };
}, { design: true });

// =================================================================== G3 RPCs as a user
await attack("G3a", "start and stop another user's plant", async () => {
  const a = await user("g3a"); const bad = [];
  const before = sql("select string_agg(user_id||':'||paused,',' order by user_id) from public.plant_users where plant_id=6004");
  for (const f of ["api_plant_start", "api_plant_stop", "api_billing_keep"]) {
    const r = await rpc(a, f, { p_plant: 6004 });
    if (good(r) && f !== "api_billing_keep") bad.push(f);
  }
  const after = sql("select string_agg(user_id||':'||paused,',' order by user_id) from public.plant_users where plant_id=6004");
  if (before !== after) bad.push("rows changed");
  return { hit: bad.length > 0, note: bad.join(",") };
});
await attack("G3b", "start a plant past the plan with no payment (Free, Home, Family)", async () => {
  const bad = [];
  const f = await user("g3f"); await link(f, "installer@mock");            // 1 active, 4 paused
  const paused = sql(`select plant_id from public.plant_users where user_id='${f.id}' and paused order by plant_id limit 1`);
  if (good(await rpc(f, "api_plant_start", { p_plant: Number(paused) }))) bad.push("free");
  const h = await home("g3h"); await link(h, "installer@mock");
  const hp = sql(`select plant_id from public.plant_users where user_id='${h.id}' and paused order by plant_id limit 1`);
  if (good(await rpc(h, "api_plant_start", { p_plant: Number(hp) }))) bad.push("home");
  const fa = await family("g3fam"); await link(fa, "installer@mock", { confirmCost: "paused" }); await link(fa, "farm@mock", { confirmCost: "paused" });
  const fp = sql(`select plant_id from public.plant_users where user_id='${fa.id}' and paused order by plant_id limit 1`);
  if (active(fa) !== 5 || !fp) bad.push("family link did not leave 2 stopped: " + active(fa));
  else if (good(await rpc(fa, "api_plant_start", { p_plant: Number(fp) }))) bad.push("family 6th");
  return { hit: bad.length > 0, note: bad.join(",") };
});
await attack("G3c", "parallel api_plant_start goes past the plan's plant limit (Free has no billing row)", async () => {
  const bad = [];
  for (const [kind, mk, lim] of [["free", () => user("g3c-free"), 1], ["home", () => home("g3c-home"), 2], ["family", () => family("g3c-fam"), 5]]) {
    const a = await mk(); await link(a, "installer@mock", { confirmCost: "paused" }); await link(a, "farm@mock", { confirmCost: "paused" });
    for (const p of sql(`select plant_id from public.plant_users where user_id='${a.id}' and not paused`).split("\n").filter(Boolean)) await rpc(a, "api_plant_stop", { p_plant: Number(p) });
    const ids = sql(`select plant_id from public.plant_users where user_id='${a.id}' order by plant_id`).split("\n").map(Number);
    const hasRow = num(`select count(*) from private.billing where user_id='${a.id}'`);
    await Promise.all(ids.map((p) => rpc(a, "api_plant_start", { p_plant: p })));
    if (active(a) > lim) bad.push(`${kind}: active=${active(a)} of limit ${lim} (billing row=${hasRow})`);
  }
  return { hit: bad.length > 0, note: bad.join("; ") };
});
await attack("G3f", "another user's login, account id or plant in link/billing calls", async () => {
  const v = await user("g3fv"); const r = await link(v, "solo@mock"); const acc = r.data.accountId;
  const a = await user("g3fa"); const bad = [];
  const before = sql(`select count(*) from private.sunsynk_accounts where id='${acc}'`) + sql(`select count(*) from public.plant_users where user_id='${v.id}'`);
  for (const f of ["api_link_disconnect", "api_link_remove"]) if (good(await rpc(a, f, { p_account: acc }))) bad.push(f);
  await rpc(a, "api_billing_keep", { p_plant: 6003 });
  const after = sql(`select count(*) from private.sunsynk_accounts where id='${acc}'`) + sql(`select count(*) from public.plant_users where user_id='${v.id}'`);
  if (before !== after) bad.push("victim rows changed");
  const adm = await rpc(a, "admin_overview"); if (good(adm)) bad.push("admin_overview");
  for (const f of ["api_link_status", "api_plant_states", "api_notifications", "api_me", "api_billing_status"]) {
    const x = await rpc(a, f); if (good(x) && new RegExp(v.id + "|" + v.email.split("@")[0]).test(JSON.stringify(x.data))) bad.push(f + " shows victim");
  }
  const noJwt = await http("POST", `${FN}/link-sunsynk`, { headers: { Origin: ORIGIN }, body: { username: "solo@mock", password: "x" } });
  if (noJwt.status === 200) bad.push("link without a session");
  const junk = await http("POST", `${FN}/link-sunsynk`, { jwt: "not.a.jwt", headers: { Origin: ORIGIN }, body: { username: "solo@mock", password: "x" } });
  if (junk.status === 200) bad.push("link with junk jwt");
  return { hit: bad.length > 0, note: bad.join(",") };
});
// A wrong login: a link that works gives its try back (0135), so the cap is for guessing.
await attack("G6g", "ten wrong logins at once get past the 5-an-hour cap", async () => {
  const a = await user("g6g"); sql(`delete from private.link_attempts where user_id='${a.id}'`);
  const rs = await Promise.all(Array.from({ length: 10 }, () => http("POST", `${FN}/link-sunsynk`, { jwt: a.jwt, headers: { Origin: ORIGIN }, body: { username: "nobody@mock", password: "x" } })));
  const tried = rs.filter((r) => r.status !== 429).length;
  return { hit: tried > 5, note: `${tried} reached SunSynk` };
});
await attack("G3d", "crafted api_billing_change / quote / keep arguments", async () => {
  const bad = []; const f = await user("g3f2"); const h = await home("g3h2");
  const before = sql(`select plan||coalesce(next_plan,'-')||coalesce(next_period,'-')||plants_to_remove::text from private.billing where user_id='${h.id}'`);
  for (const [who, args] of [[f, { p_plan: "family", p_period: "monthly" }], [h, { p_plan: "family", p_period: "yearly" }], [h, { p_plan: "'; drop table x;--", p_period: "monthly" }],
    [h, { p_plan: "free", p_period: "weekly" }], [h, { p_plan: "home", p_period: "yearly" }], [h, { p_plan: null, p_period: null }], [h, { p_plan: "family", p_period: null }]]) {
    const r = await rpc(who, "api_billing_change", args);
    const after = sql(`select plan from private.billing where user_id='${h.id}'`);
    if (after !== "home") bad.push("plan became " + after);
    if (good(r) && who === f) bad.push("free changed plan");
  }
  // booking undone again
  await rpc(h, "api_billing_change", { p_plan: "home", p_period: "monthly" });
  for (const args of [{ p_plan: "family", p_extra: -50 }, { p_plan: "family", p_extra: 2147483647 }, { p_plan: null }, { p_plan: "free" }, { p_plan: "family", p_period: "x" }, { p_plan: "family", p_extra: "1; select 1" }]) {
    const r = await rpc(h, "api_billing_quote", args);
    if (good(r) && Number(r.data?.dueNow) < 0) bad.push("negative quote");
    const r2 = await rpc(f, "api_billing_quote", { ...args, p_period: "monthly" });
    if (good(r2) && Number(r2.data?.dueNow) < 0) bad.push("negative quote free");
  }
  const kept = await rpc(h, "api_billing_keep", { p_plant: -1 });
  void kept;
  const end = sql(`select plan||coalesce(next_plan,'-')||coalesce(next_period,'-')||plants_to_remove::text from private.billing where user_id='${h.id}'`);
  if (end !== before) bad.push("billing row changed: " + before + " -> " + end);
  return { hit: bad.length > 0, note: bad.join("; ") };
});
await attack("G3e", "a user calls billing_charge_paid / set_comped / renew on their own charge or row", async () => {
  const a = await user("g3e"); const bad = [];
  const o = await svc("billing_charge_open", { p_user: a.id, p_plan: "family", p_period: "monthly" });
  const r = await rpc(a, "billing_charge_paid", { p_reference: o.data.reference, p_card: null, p_quiet: true, p_cents: o.data.amount * 100 });
  if (good(r) || planOf(a) !== "free") bad.push("charge_paid");
  const r2 = await rpc(a, "billing_renew", { p_user: a.id }); if (good(r2)) bad.push("renew");
  const r3 = await rpc(a, "billing_set_comped", { p_user: a.id, p_comped: true }); if (good(r3)) bad.push("set_comped");
  const r4 = await rpc(null, "billing_charge_paid", { p_reference: o.data.reference, p_cents: o.data.amount * 100 }); if (good(r4)) bad.push("anon charge_paid");
  return { hit: bad.length > 0, note: bad.join(",") };
});

// =================================================================== G4 pay endpoint inputs (through the SQL it calls)
await attack("G4a", "pay endpoint answers 503 and checks nothing before the key (local has no Paystack key)", async () => {
  const a = await user("g4a"); const bad = [];
  for (const [route, h] of [["pay", { Origin: ORIGIN }], ["verify", {}], ["webhook", {}], ["run", {}]]) {
    const r = await http("POST", `${FN}/billing/${route}`, { jwt: a.jwt, body: { plan: "family", reference: "psh_x" }, headers: h });
    if (r.status === 200) bad.push(route + ":200");
  }
  const r = await http("POST", `${FN}/billing/run`, { jwt: a.jwt, body: {} });   // a user token is not a server key
  if (r.status === 200) bad.push("run with user jwt");
  return { hit: bad.length > 0, note: bad.join(",") };
});
await attack("G4b", "crafted pay bodies: bad plan, period, extras (opened as /billing/pay does)", async () => {
  const bad = []; const a = await user("g4b");
  for (const body of [{ plan: "free" }, { plan: "pro" }, { plan: "" }, { plan: "home", period: "weekly" }, { plan: "home", period: "yearly; x" }, { plan: "family", extras: 1.5 },
    { plan: "family", extras: 1e12 }, { plan: "family", extras: -3 }, { plan: "family", extras: "abc", period: "monthly" }]) {
    const o = await pay(a, body);
    const pl = planOf(a);
    if (!o.err && !(body.plan === "family" || body.plan === "home")) bad.push("accepted " + JSON.stringify(body));
    if (!o.err && o.amount !== undefined && o.amount < priceAt(o.reference, body.plan, "monthly") && body.period !== "yearly") bad.push(`cheap ${JSON.stringify(body)} R${o.amount}`);
    if (pl !== "free") { sql(`delete from private.billing where user_id='${a.id}'`); }
  }
  return { hit: bad.length > 0, note: bad.join("; ") };
});
await attack("G4c", "Family pays extras (more, the same, fewer, negative): nothing charged, nothing changed (0156: none sold)", async () => {
  const bad = [];
  const a = await family("g4c"); holdExtras(a, 2);
  for (const n of [3, 2, 1, 0, -1]) {
    const o = await pay(a, { plan: "family", extras: n });
    if (!o.err) bad.push(`extras ${n} opened R${o.amount}`);
  }
  const held = num(`select extra_plants from private.billing where user_id='${a.id}'`);
  if (held !== 2) bad.push(`extras now ${held}`);
  return { hit: bad.length > 0, note: bad.join("; ") };
});
await attack("G4d", "a plant with no inverter rows still needs room bought", async () => {
  const a = await family("g4d");
  const acc = await link(a, "solo@mock");                            // gives a real account id
  const accId = acc.data?.accountId;
  const ghost = 9264000 + Number(RUN) % 1000;
  sql(`insert into public.plant_users (plant_id,user_id,account_id,plant_name) select p,'${a.id}','${accId}','f'||p from unnest(array[${ghost + 1},${ghost + 2},${ghost + 3},${ghost + 4}]) p`);
  sql(`select public.plant_users_upsert('${a.id}','${accId}','[{"plant_id":${ghost},"plant_name":"ghost"}]'::jsonb)`);   // the 6th: links stopped
  const o = await pay(a, { plan: "family" });                                                                          // nothing bought
  const s1 = await rpc(a, "api_plant_start", { p_plant: ghost });
  const started = num(`select count(*) from public.plant_users where user_id='${a.id}' and plant_id=${ghost} and not paused`);
  sql(`delete from public.plant_users where user_id='${a.id}' and plant_id between ${ghost} and ${ghost + 4}`);
  sql(`delete from public.plant_config where plant_id between ${ghost} and ${ghost + 4}`);
  return { hit: started === 1, note: `started=${started}, pay: ${o.err ?? "R" + o.amount}, start ${s1.status}` };
});
await attack("G4e", "stale cheap upgrade charge paid after the next renewal", async () => {
  const h = await home("g4e");
  sql(`update private.billing set next_billing_date = (now() at time zone 'Africa/Johannesburg')::date + 1,
        billing_day = extract(day from (now() at time zone 'Africa/Johannesburg')::date + 1)::int where user_id='${h.id}'`);
  // last day of the period: open the upgrade charge (as /billing/pay with newCard does), do not pay yet
  const o = await svc("billing_charge_open", { p_user: h.id, p_plan: "family", p_period: null });
  // the renewal runs: Home is charged again and the period moves a month on
  sql(`update private.billing set next_billing_date = next_billing_date where user_id='${h.id}'`);
  await svc("billing_renew", { p_user: h.id });
  const fair = (await rpc(h, "api_billing_quote", { p_plan: "family" })).data?.dueNow;
  const p = await svc("billing_charge_paid", { p_reference: o.data.reference, p_card: null, p_quiet: true, p_cents: o.data.amount * 100 });
  const plan = planOf(h);
  return { hit: plan === "family" && o.data.amount < fair, note: `paid R${o.data.amount}, a fresh upgrade now costs R${fair}; plan=${plan}; ${good(p) ? "" : p.status}` };
});
await attack("G4f", "charge paid twice, and two start charges both paid", async () => {
  const a = await user("g4f"); const bad = [];
  const c1 = await svc("billing_charge_open", { p_user: a.id, p_plan: "home", p_period: "monthly" });
  const c2 = await svc("billing_charge_open", { p_user: a.id, p_plan: "family", p_period: "yearly" });
  await svc("billing_charge_paid", { p_reference: c1.data.reference, p_cents: c1.data.amount * 100 });
  const d1 = sql(`select next_billing_date from private.billing where user_id='${a.id}'`);
  await svc("billing_charge_paid", { p_reference: c1.data.reference, p_cents: c1.data.amount * 100 });
  await svc("billing_charge_paid", { p_reference: c2.data.reference, p_cents: c2.data.amount * 100 });
  if (planOf(a) !== "home") bad.push("second start applied: " + planOf(a));
  if (sql(`select next_billing_date from private.billing where user_id='${a.id}'`) !== d1) bad.push("billing date moved");
  const wrong = await svc("billing_charge_paid", { p_reference: (await svc("billing_charge_open", { p_user: a.id, p_plan: "family", p_period: null })).data.reference, p_cents: 100 });
  if (good(wrong)) bad.push("paid R1 for a bigger charge");
  return { hit: bad.length > 0, note: bad.join("; ") };
});

// =================================================================== G5 verify, webhook, settle, card
await attack("G5a", "settle and card-change are refused when they do not apply", async () => {
  const a = await home("g5a"); const f = await user("g5f"); const bad = [];
  if (good(await svc("billing_settle_open", { p_user: a.id }))) bad.push("settle when not past due");
  if (good(await svc("billing_card_open", { p_user: f.id }))) bad.push("card change on Free");
  sql(`update private.billing set state='past_due', past_due_since=current_date where user_id='${a.id}'`);
  if (good(await svc("billing_charge_open", { p_user: a.id, p_plan: "family", p_period: null })) ) bad.push("upgrade while past due");
  return { hit: bad.length > 0, note: bad.join(",") };
});
await attack("G5b", "card details never reach the browser", async () => {
  const a = await home("g5b");
  sql(`update private.billing set card='{"authorization_code":"AUTH_SECRETXYZ","last4":"4081","brand":"visa","reusable":true,"signature":"SIG_SECRETXYZ"}'::jsonb where user_id='${a.id}'`);
  const blob = JSON.stringify([await rpc(a, "api_billing_status"), await rpc(a, "api_me"), await rpc(a, "api_link_status"), await rpc(a, "api_plant_states"), await rest(a, "GET", "profiles")]);
  return { hit: /SECRETXYZ|authorization_code/.test(blob) };
});
await attack("G5c", "billing function source: webhook signature, verify, run, origin (read from the code)", async () => {
  const src = (await import("node:fs")).readFileSync(path.join(REPO, "supabase/functions/billing/index.ts"), "utf8");
  const bad = [];
  if (!/timingSafeEqual/.test(src) || !/got\.length !== want\.length/.test(src)) bad.push("webhook compare");
  if (!/denyUnlessServer\(req\)/.test(src)) bad.push("run unguarded");
  if (!/p_cents: tx\.amount/.test(src) || !/tx\.currency === "ZAR"/.test(src)) bad.push("amount/currency not checked");
  if (!/startsWith\("psh_"\)/.test(src)) bad.push("reference prefix");
  if (!/origin not allowed/.test(src)) bad.push("origin check");
  return { hit: bad.length > 0, note: bad.join(",") };
});
await attack("G5d", "verify: another user's payment reference is refused (SOLAR-208)", async () => {
  const a = await user("g5d-a"); const b = await user("g5d-b"); const bad = [];
  const o = await svc("billing_charge_open", { p_user: a.id, p_plan: "home", p_period: "monthly" });
  if (!good(o)) throw new Error(`open charge: ${o.data?.message || o.status}`);
  const ref = o.data.reference;
  // the owner lookup is the server's alone
  if (good(await rpc(b, "billing_charge_user", { p_reference: ref }))) bad.push("owner lookup open to users");
  if (sql(`select public.billing_charge_user('${ref}') = '${a.id}'`) !== "t") bad.push("owner lookup wrong");
  // Through the function: needs it served with a Paystack key (the mock); without one every route answers 503.
  const verify = (u) => http("POST", `${FN}/billing/verify`, { jwt: u.jwt, body: { reference: ref } });
  const rb = await verify(b);
  if (rb.status === 503) return { hit: bad.length > 0, note: [...bad, "HTTP part skipped: billing served without a Paystack key"].join(",") };
  if (rb.status !== 400 || rb.data?.error !== "unknown reference") bad.push(`other user got ${rb.status}`);
  if ((await verify(a)).status === 400) bad.push("owner refused too");
  return { hit: bad.length > 0, note: bad.join(",") };
});

// =================================================================== G6 link flow
await attack("G6a", "Family: parallel links of six logins (8 plants) pass the 5-plant cover with no payment", async () => {
  const a = await family("g6a");
  const rs = await Promise.all(["nobatt@mock", "shared@mock", "export@mock", "brynne@mock", "farm@mock", "flat@mock"].map((l) => link(a, l, { confirmCost: true })));
  const n = active(a);
  return { hit: n > 5, note: `${n} plants collecting on Family (5 covered), statuses ${rs.map((r) => r.status).join(",")}` };
});
await attack("G6b", "Free and Home: parallel links stay at 1 and 2 plants", async () => {
  const bad = [];
  for (const [mk, lim] of [[() => user("g6b-free"), 1], [() => home("g6b-home"), 2]]) {
    const a = await mk();
    await Promise.all(["nobatt@mock", "shared@mock", "export@mock", "brynne@mock", "installer@mock"].map((l) => link(a, l, { confirmCost: true })));
    if (active(a) > lim) bad.push(`${planOf(a)} active=${active(a)}`);
  }
  return { hit: bad.length > 0, note: bad.join(",") };
});
await attack("G6c", "old confirmCost values on a Family 6th+7th plant: no cost question, never past the room", async () => {
  const bad = [];
  for (const cc of [undefined, false, 1, "yes", true, "paused"]) {
    const a = await family("g6c");
    await link(a, "installer@mock");
    const r = await link(a, "farm@mock", cc === undefined ? {} : { confirmCost: cc });
    if (r.status !== 200) bad.push(`${JSON.stringify(cc)} -> ${r.status}`);
    if (active(a) > 5) bad.push(`${JSON.stringify(cc)} active=${active(a)}`);
  }
  return { hit: bad.length > 0, note: bad.join("; ") };
});
await attack("G6d", "Free: remove login and relink does not restart the free week", async () => {
  const a = await user("g6d"); const r = await link(a, "solo@mock");
  const t0 = sql(`select started_at from private.free_week_logins where user_id='${a.id}'`);
  await rpc(a, "api_link_remove", { p_account: r.data.accountId });
  const r2 = await link(a, "solo@mock");
  const t1 = sql(`select started_at from private.free_week_logins where user_id='${a.id}'`);
  return { hit: t0 !== t1 || !r2.data?.accountId, note: "week start kept: " + (t0 === t1) };
});
await attack("G6e", "Free: a second account links the same login and gets its own free week", async () => {
  const a = await user("g6e1"), b = await user("g6e2");
  await link(a, "solo@mock"); const r = await link(b, "solo@mock");
  return { hit: r.status === 200 && active(b) === 1, note: "0121: every account gets one free week, on any plant, even one another account has" };
}, { design: true });
await attack("G6f", "paid link then cancel: no free-week row, so the plant is never trimmed on Free", async () => {
  const a = await home("g6f"); await link(a, "solo@mock");
  const rowsBefore = num(`select count(*) from private.free_week_logins where user_id='${a.id}'`);
  await rpc(a, "api_billing_change", { p_plan: "free" });
  sql(`update private.billing set next_billing_date = current_date where user_id='${a.id}'`);
  await svc("billing_renew", { p_user: a.id });
  sql(`update private.free_week_logins set started_at = started_at where user_id='${a.id}'`);
  const trimmed = num(`select count(*) from public.free_trimmed_plants() p where p = 6003`);   // shared with a paying user, so also check the rule itself:
  const rule = num(`select count(*) from public.plant_users pu left join private.billing b on b.user_id=pu.user_id left join lateral (select min(started_at) s from private.free_week_logins f where f.user_id=pu.user_id) fw on true
                      where pu.user_id='${a.id}' and coalesce(b.plan,'free')='free' and fw.s is not null`);
  return { hit: planOf(a) === "free" && rowsBefore === 0 && rule === 0, note: `Free, free-week rows=${rowsBefore}, trimmable=${rule}; shared-plant trim=${trimmed}` };
});

// =================================================================== G7 plan tricks
await attack("G7a", "book Home (or Free) then link new plants: they stay active after the renewal", async () => {
  const bad = [];
  for (const target of ["home", "free"]) {
    const a = await family("g7a");
    await link(a, "solo@mock");                                            // 1 plant: booking is allowed
    const b = await rpc(a, "api_billing_change", { p_plan: target });
    if (!good(b)) { bad.push("booking refused " + target); continue; }
    await link(a, "installer@mock", { confirmCost: true });                // more plants while still Family
    sql(`update private.billing set next_billing_date = current_date where user_id='${a.id}'`);
    await svc("billing_renew", { p_user: a.id });
    const lim = target === "home" ? 2 : 1;
    if (active(a) > lim) bad.push(`${target}: ${active(a)} plants active on ${planOf(a)} (limit ${lim})`);
  }
  return { hit: bad.length > 0, note: bad.join("; ") };
});
await attack("G7b", "Family: book removal of a login, link others: more than 5 collect until the date", async () => {
  const a = await family("g7b");
  const r = await link(a, "solo@mock");                                    // 6003
  const rm = await rpc(a, "api_link_remove", { p_account: r.data.accountId });     // removed now (0139)
  await link(a, "shared@mock", { confirmCost: true });                     // 6004
  await link(a, "export@mock", { confirmCost: true });                     // 3001, 6002
  await link(a, "brynne@mock", { confirmCost: true });                     // 5001
  await link(a, "farm@mock", { confirmCost: true });                       // 6008, 6009
  const n = active(a);
  return { hit: n > 5, note: `${n} collecting, 5 paid; removal ${rm.data?.result}` };
});
await attack("G7c", "stop an extra plant before renewal, start it again after: only while its room is still billed", async () => {
  const a = await family("g7c"); holdExtras(a, 1); await link(a, "installer@mock"); await link(a, "farm@mock");
  const ex = num(`select plant_id from public.plant_users where user_id='${a.id}' and not paused order by linked_at desc, plant_id desc limit 1`);
  await rpc(a, "api_plant_stop", { p_plant: ex });
  sql(`update private.billing set next_billing_date = current_date where user_id='${a.id}'`);
  const r = await svc("billing_renew", { p_user: a.id });
  const s = await rpc(a, "api_plant_start", { p_plant: ex });
  // Family and one extra plant, at the offer the account holds
  const full = num(`select public.billing_amount('family', 'monthly', 1, private.billing_offer('${a.id}', private.billing_today()))`);
  return { hit: good(s) && active(a) > 5 && r.data?.charge < full, note: `renewal charge R${r.data?.charge}, restart ${s.status}` };
});
await attack("G7d", "upgrade on the billing date costs nothing, then downgrade is booked", async () => {
  const h = await home("g7d");
  sql(`update private.billing set next_billing_date = (now() at time zone 'Africa/Johannesburg')::date where user_id='${h.id}'`);
  const q = (await rpc(h, "api_billing_quote", { p_plan: "family" })).data?.dueNow;
  return { hit: Number(q) === 0, note: `Home to Family quote on the billing date: R${q} (the 06:00 run then renews as Family at full price)` };
}, { design: true });
await attack("G7e", "account delete while past due is refused, so the debt stays", async () => {
  const a = await home("g7e"); sql(`update private.billing set state='past_due', past_due_since=current_date where user_id='${a.id}'`);
  const r = await rpc(a, "api_account_delete");
  const left = num(`select (select count(*) from private.billing where user_id='${a.id}') + (select count(*) from public.plant_users where user_id='${a.id}')`);
  // Decided 2026-10-31 (0130): delete is refused while money is owed.
  return { hit: good(r) || left === 0, note: "past-due account deleted: the debt went with it" };
});

// =================================================================== G8 data exposure
const ARGS = { api_energy: { p_period: "week" }, api_export: { p_from: "2026-10-01", p_to: "2026-10-30" }, api_history: { p_date: "2026-10-29" },
  api_inverter_history: { p_date: "2026-10-29" }, api_trends_by_hour: { p_days: 7 }, api_trends_daily: { p_days: 7 }, q_by_hour: { p_days: 7 },
  q_day_agg: { p_day: "2026-10-29" }, q_day_gap_minutes: { p_day: "2026-10-29" }, q_grid_present: { p_ts: Math.floor(Date.now() / 1000) - 600 },
  q_recovered_minutes: { p_day: "2026-10-29" }, _plant_day_energy: { p_from: "2026-10-01", p_to: "2026-10-30" } };
const PLANT_FNS = ["api_balance", "api_data_days", "api_db_stats", "api_energy", "api_export", "api_grid_off_recent", "api_health", "api_history", "api_history_earliest",
  "api_inverter_history", "api_overview", "api_plant_days", "api_string_health", "api_trends_by_hour", "api_trends_compare", "api_trends_daily",
  "plant_cfg", "plant_tz", "q_by_hour", "q_day_agg", "q_day_gap_minutes", "q_grid_present", "q_recovered_minutes", "q_stats", "_plant_day_energy"];
async function readLeaks(u, plant) {
  const bad = [];
  for (const f of PLANT_FNS) {
    const args = { ...(ARGS[f] || {}), p_plant: plant }, base = { ...(ARGS[f] || {}), p_plant: 987654321 };
    const [r, b] = await Promise.all([rpc(u, f, args), rpc(u, f, base)]);
    if (good(r) && (!good(b) || JSON.stringify(r.data) !== JSON.stringify(b.data))) bad.push(f);
  }
  for (const t of ["readings", "agg_minute", "plant_energy", "strings", "inverter_history", "grid_off", "config_changes", "plant_config"]) {
    const r = await rest(u, "GET", `${t}?plant_id=eq.${plant}&limit=1`); if (rows(r) > 0) bad.push("table " + t);
  }
  return bad;
}
await attack("G8a", "read another user's plant (readings, settings, every p_plant function)", async () => {
  const a = await user("g8a"); const bad = await readLeaks(a, 6004);
  const anon = await rpc(null, "api_overview", { p_plant: 6004 }); if (good(anon)) bad.push("anon overview");
  return { hit: bad.length > 0, note: bad.join(",") };
});
await attack("G8b", "read a plant I stopped (data not mine to see while stopped)", async () => {
  const a = await user("g8b"); await link(a, "shared@mock");                        // 6004: has data, others collect it
  const before = await readLeaks(a, 6004);                                             // active: expect the oracle to see data
  await rpc(a, "api_plant_stop", { p_plant: 6004 });
  const bad = await readLeaks(a, 6004);
  return { hit: bad.length > 0, note: `data visible while active: ${before.length > 0}; after stop: ${bad.join(",")}` };
});
await attack("G8c", "own-only tables show only own rows", async () => {
  const a = await user("g8c"), b = await user("g8c2"); await link(b, "solo@mock");
  const bad = [];
  for (const t of ["plant_users", "profiles", "email_prefs", "push_prefs"]) {
    const r = await rest(a, "GET", t); if ((r.data || []).some?.((x) => x.user_id && x.user_id !== a.id)) bad.push(t);
  }
  const n = await rpc(a, "api_notifications"); if (JSON.stringify(n.data).includes(b.id)) bad.push("notifications");
  return { hit: bad.length > 0, note: bad.join(",") };
});
await attack("G8d", "api_push_sub takes over another user's push endpoint", async () => {
  const a = await user("g8d1"), b = await user("g8d2"); const ep = "https://push.example/atk-" + RUN;
  await rpc(a, "api_push_sub", { p_endpoint: ep, p_p256dh: "k1", p_auth: "a1", p_platform: "web" });
  await rpc(b, "api_push_sub", { p_endpoint: ep, p_p256dh: "k2", p_auth: "a2", p_platform: "web" });
  const owner = sql(`select user_id from public.push_subs where endpoint='${ep}'`);
  sql(`delete from public.push_subs where endpoint='${ep}'`);
  return { hit: owner === b.id, note: "needs the victim's secret endpoint URL" };
}, { design: true });

// =================================================================== C many requests at once (--seed sets the order)
// Family plants collecting past the room: 5 plus extras still held (0156)
const extrasPaid = (u) => Math.max(0, active(u) - 5 - num(`select coalesce((select extra_plants from private.billing where user_id='${u.id}'), 0)`));
const ok = (u) => {
  const plan = planOf(u), comped = sql(`select coalesce((select comped from private.billing where user_id='${u.id}'), false)`) === "t";
  if (comped) return null;
  if (plan !== "family" && active(u) > (plan === "home" ? 2 : 1)) return `${plan}: ${active(u)} collect`;
  if (plan === "family" && extrasPaid(u) > 0) return `family: ${extrasPaid(u)} plants collect past the room bought`;
  // A booked downgrade lets every plant collect to the billing date, then stops those past
  // the pick (0136, decided 2026-11-01); C2 checks the stop at renewal.
  return null;
};
await attack("C1", "a storm on each plan: links, stops, starts, pays, bookings all at once", async () => {
  const bad = [];
  for (const mk of [() => user("c1-free"), () => home("c1-home"), () => family("c1-fam")]) {
    const a = await mk();
    await link(a, "solo@mock");
    const logins = shuffle(["installer@mock", "export@mock", "shared@mock", "farm@mock", "business@mock"]);
    const ids = () => sql(`select string_agg(plant_id::text, ',') from public.plant_users where user_id='${a.id}'`).split(",").filter(Boolean).map(Number);
    for (let round = 0; round < 3; round++) {
      const reqs = [
        ...logins.slice(round, round + 2).map((l) => () => link(a, l, { confirmCost: rnd() < 0.5 ? true : "paused" })),
        ...ids().flatMap((p) => [() => rpc(a, "api_plant_start", { p_plant: p }), () => rpc(a, "api_plant_start", { p_plant: p }), () => rpc(a, "api_plant_stop", { p_plant: p })]),
        () => pay(a, { plan: "family", extras: 1 + Math.floor(rnd() * 3) }),
        () => pay(a, { plan: "family", extras: 1 }),
        () => rpc(a, "api_billing_extras", { p_count: 0 }),
        () => rpc(a, "api_billing_change", { p_plan: rnd() < 0.5 ? "home" : "free" }),
        () => rpc(a, "api_billing_change", { p_plan: planOf(a) }),
      ];
      await Promise.all(shuffle(reqs).map((f) => f().catch((e) => e)));
      const why = ok(a); if (why) bad.push(`round ${round}: ${why}`);
    }
  }
  return { hit: bad.length > 0, note: bad.join("; ") };
});
await attack("C2", "renewal of a booked downgrade while links and starts run", async () => {
  const bad = [];
  for (const target of ["home", "free"]) {
    const a = await family("c2-" + target);
    await link(a, "solo@mock");
    await rpc(a, "api_billing_change", { p_plan: target });
    sql(`update private.billing set next_billing_date = (now() at time zone 'Africa/Johannesburg')::date where user_id='${a.id}'`);
    const ids = sql(`select string_agg(plant_id::text, ',') from public.plant_users where user_id='${a.id}'`).split(",").map(Number);
    await Promise.all(shuffle([
      () => link(a, "installer@mock", { confirmCost: true }), () => link(a, "export@mock", { confirmCost: true }),
      () => svc("billing_renew", { p_user: a.id }),
      ...ids.map((p) => () => rpc(a, "api_plant_start", { p_plant: p })),
    ]).map((f) => f().catch((e) => e)));
    const late = sql(`select string_agg(plant_id::text, ',') from public.plant_users where user_id='${a.id}' and paused`).split(",").filter(Boolean).map(Number);
    await Promise.all(late.map((p) => rpc(a, "api_plant_start", { p_plant: p })));
    if (active(a) > (target === "home" ? 2 : 1)) bad.push(`${target}: ${active(a)} collect on ${planOf(a)}`);
  }
  return { hit: bad.length > 0, note: bad.join("; ") };
});
await attack("C3", "one charge reported paid ten times at once, and two upgrades paid at once", async () => {
  const bad = [];
  const a = await home("c3");
  const o1 = await svc("billing_charge_open", { p_user: a.id, p_plan: "family", p_period: null });
  const o2 = await svc("billing_charge_open", { p_user: a.id, p_plan: "family", p_period: null });
  await Promise.all(shuffle([...Array(10).fill(o1), o2]).map((o) => svc("billing_charge_paid", { p_reference: o.data.reference, p_quiet: true, p_cents: o.data.amount * 100 })));
  const applied = num(`select count(*) from private.billing_charges where user_id='${a.id}' and kind='upgrade' and status='paid' and error is null`);
  const flagged = num(`select count(*) from private.billing_charges where user_id='${a.id}' and kind='upgrade' and status='paid' and error like 'refund%'`);
  if (applied !== 1) bad.push(`${applied} upgrades applied`);
  if (o1.data.amount > 0 && flagged !== 1) bad.push(`${flagged} marked for refund, want 1`);
  return { hit: bad.length > 0, note: bad.join("; ") };
});
await attack("C4", "comped account: many links and starts at once all collect", async () => {
  const a = await user("c4");
  sql(`insert into private.billing (user_id, plan, comped) values ('${a.id}', 'family', true)`);
  await Promise.all(shuffle(["installer@mock", "export@mock", "shared@mock", "brynne@mock", "solo@mock"]).map((l) => link(a, l)));
  const total = num(`select count(*) from public.plant_users where user_id='${a.id}'`);
  return { hit: active(a) !== total, note: `${active(a)} of ${total} collect` };
});



} finally {
  let msg = "";
  try { msg = await cleanup(); } catch (e) { msg = "cleanup failed: " + e.message; broken++; }
  if (mockStarted) mockStarted.kill();
  const hits = RESULTS.filter((r) => r.hit && !r.design);
  console.log(`\n${RESULTS.length} attacks: ${hits.length} worked, ${RESULTS.filter((r) => r.hit && r.design).length} by design, ${broken} errors. Cleanup: ${msg}`);
  process.exitCode = broken ? 2 : hits.length ? 1 : 0;
}
