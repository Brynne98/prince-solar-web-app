// Many owners opening pages at once, over HTTP through PostgREST (SOLAR-210).
// Each owner signs in as their own fake user and loads what the Live and Solar
// pages ask for: overview, today's history, the week's energy, 30-day trends.
// For each owner count C, fire C page loads together every 15 s for 3 minutes.
//
//   node load-test/pages.mjs <jwt-secret-file> 10 50 100 250
import { createHmac } from "node:crypto";
import { readFileSync, appendFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const [secretFile, ...counts] = process.argv.slice(2);
const SECRET = readFileSync(secretFile, "utf8").trim();
const API = "http://127.0.0.1:54400/rest/v1/rpc";
const OUT = process.env.OUT;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const jwt = (sub) => {
  const body = `${b64({ alg: "HS256", typ: "JWT" })}.${b64({ role: "authenticated", sub, exp: 4102444800 })}`;
  return `${body}.${createHmac("sha256", SECRET).update(body).digest("base64url")}`;
};

const owners = JSON.parse(execFileSync("docker", ["exec", "solar-loadtest-client", "psql", "-h", "solar-loadtest-db", "-U", "postgres", "-Atq", "-c",
  "select json_agg(json_build_object('plant', plant_id, 'user', user_id) order by plant_id) from public.plant_users where plant_id > 900000"], { encoding: "utf8" }));

const CALLS = [
  ["api_overview", {}], ["api_history", { p_date: null }], ["api_energy", { p_period: "week" }], ["api_trends_daily", { p_days: 30 }],
];

async function call(token, plant, fn, args) {
  const t0 = performance.now();
  const r = await fetch(`${API}/${fn}`, {
    method: "POST", headers: { Authorization: `Bearer ${token}`, apikey: token, "Content-Type": "application/json" },
    body: JSON.stringify({ ...args, p_plant: plant }),
  });
  await r.arrayBuffer();
  return { ms: performance.now() - t0, ok: r.ok };
}

const pct = (xs, p) => xs[Math.min(xs.length - 1, Math.floor(xs.length * p))];

for (const C of counts.map(Number)) {
  const who = owners.slice(0, C).map((o) => ({ ...o, token: jwt(o.user) }));
  const ms = [], pageMs = [];
  let failed = 0;
  for (let burst = 0; burst < 12; burst++) {
    const start = performance.now();
    await Promise.all(who.map(async (o) => {
      const t0 = performance.now();
      const rs = await Promise.all(CALLS.map(([fn, a]) => call(o.token, o.plant, fn, a)));
      for (const r of rs) { ms.push(r.ms); if (!r.ok) failed++; }
      pageMs.push(performance.now() - t0);
    }));
    await sleep(Math.max(0, 15_000 - (performance.now() - start)));
  }
  ms.sort((a, b) => a - b); pageMs.sort((a, b) => a - b);
  const row = {
    owners: C, calls: ms.length, failed,
    callP50: Math.round(pct(ms, 0.5)), callP95: Math.round(pct(ms, 0.95)), callMax: Math.round(ms.at(-1)),
    pageP50: Math.round(pct(pageMs, 0.5)), pageP95: Math.round(pct(pageMs, 0.95)), pageMax: Math.round(pageMs.at(-1)),
  };
  console.log(JSON.stringify(row));
  if (OUT) appendFileSync(OUT, JSON.stringify(row) + "\n");
}
