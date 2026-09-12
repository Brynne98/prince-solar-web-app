#!/usr/bin/env node
// Create the local dashboard users and link each to its mock SunSynk login(s),
// through the real link-sunsynk function. Local stack only.
//
//   eval "$(supabase status -o env | grep -E '^(API_URL|SERVICE_ROLE_KEY|ANON_KEY)=')"
//   node scripts/mock-sunsynk/seed-users.mjs
//
// Idempotent: existing users are reused, existing links are refreshed.
const API = (process.env.API_URL || "http://127.0.0.1:55321").replace(/"/g, "");
const SERVICE = (process.env.SERVICE_ROLE_KEY || "").replace(/"/g, "");
const ANON = (process.env.ANON_KEY || "").replace(/"/g, "");
if (!SERVICE || !ANON) { console.error("SERVICE_ROLE_KEY / ANON_KEY missing"); process.exit(1); }

const PASSWORD = "devpassword123"; // throwaway, same as seed.sql
// One dashboard user per customer shape, plus dev who links every login so the
// plant selector shows all of them on one screen.
const USERS = {
  "dev@local.test":    ["brynne@mock", "export@mock", "nobatt@mock", "shared@mock"],
  "family@local.test": ["family@mock"],
  "export@local.test": ["export@mock"],
  "nobatt@local.test": ["nobatt@mock"],
  "shared@local.test": ["shared@mock"],
};

const j = async (res) => { const t = await res.text(); try { return JSON.parse(t); } catch { return { raw: t }; } };

async function ensureUser(email) {
  const h = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json" };
  const list = await j(await fetch(`${API}/auth/v1/admin/users?per_page=200`, { headers: h }));
  const hit = (list.users || []).find((u) => u.email === email);
  if (hit) return hit.id;
  const r = await j(await fetch(`${API}/auth/v1/admin/users`, { method: "POST", headers: h, body: JSON.stringify({ email, password: PASSWORD, email_confirm: true }) }));
  if (!r.id) throw new Error(`create ${email}: ${JSON.stringify(r)}`);
  return r.id;
}
async function session(email) {
  const r = await j(await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" }, body: JSON.stringify({ email, password: PASSWORD }),
  }));
  if (!r.access_token) throw new Error(`sign-in ${email}: ${JSON.stringify(r)}`);
  return r.access_token;
}
async function link(jwt, username) {
  return j(await fetch(`${API}/functions/v1/link-sunsynk`, {
    method: "POST", headers: { apikey: ANON, Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
    body: JSON.stringify({ username, password: "mock" }),
  }));
}

for (const [email, logins] of Object.entries(USERS)) {
  const id = await ensureUser(email);
  const jwt = await session(email);
  for (const u of logins) {
    const r = await link(jwt, u);
    console.log(email, "->", u, r.ok ? `ok plants=${(r.plants || []).map((p) => p.id).join(",")}${r.warning ? " (" + r.warning + ")" : ""}` : `FAIL ${JSON.stringify(r)}`);
  }
  console.log("user", email, id);
}
