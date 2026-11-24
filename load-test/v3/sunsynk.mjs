// Fake SunSynk for the poller v3 load test (SOLAR-656), built on the shared mock
// (supabase/functions/_shared/mock-sunsynk.mjs): the fleet from fleet.mjs is added to its
// plants and logins, and every answer waits like production's realtime calls did over the
// last 7 days (2026-11-17..24): about 1 s on average, 11 s at most, about 0.1% a 504 after
// about 10 s. LOCAL only.
//   node load-test/v3/sunsynk.mjs <shape> [port]       shape: 500, 1000 or 3000
//   POST /__knobs {slow, slowMs:[lo,hi], r429, outage, scale}   slow/r429 = share of calls
//   GET  /__stats   calls, results, in flight now and at peak; ?reset=1 starts again
//   GET  /__last?since=<ms>   serials called since then
import http from "node:http";
import { handle, PLANTS, ACCOUNTS } from "../../supabase/functions/_shared/mock-sunsynk.mjs";
import { fleet } from "./fleet.mjs";

const shape = process.argv[2] ?? "500";
const PORT = Number(process.argv[3] ?? 4500);
const f = fleet(shape);
const plant = (p, i) => ({
  name: `Load ${p.id}`, tz: "Africa/Johannesburg", currency: "ZAR", lat: -26.2, lon: 28.0,
  kwp: 8, battKwh: 10, gridMode: "import", phases: 1, battSign: "discharging", banks: "per-inverter", loadBase: 600,
  inverters: p.sns.map((sn, j) => ({ sn, alias: sn, share: 1 / p.sns.length, upload: 60, ct: j === 0, model: "SUNSYNK-8K-SG01LP1" })),
});
for (const l of f.logins) {
  for (const p of l.plants) PLANTS[p.id] = plant(p);
  ACCOUNTS[l.username] = { plants: l.plants.map((p) => p.id), pageSize: 50 };
}
if (f.share) {
  for (const p of f.share.plants) PLANTS[p.id] = plant(p);
  ACCOUNTS[f.share.username] = { plants: f.share.plants.map((p) => p.id), pageSize: 50 };
}

let knobs = { slow: 0, slowMs: [10000, 20000], r429: 0, outage: false, scale: 1 };
const stats = { calls: 0, results: {}, inFlight: 0, peak: 0, since: Date.now() };
const lastCall = new Map();   // sn -> ms
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// lognormal around 0.8 s (mean ~1 s), cut at 9.5 s; 0.1%: a 504 after 10-11 s
function latency() {
  const z = Math.sqrt(-2 * Math.log(Math.random() || 1e-9)) * Math.cos(2 * Math.PI * Math.random());
  return Math.min(9500, 800 * Math.exp(0.6 * z)) * knobs.scale;
}
const send = (res, status, json) => { res.writeHead(status, { "Content-Type": "application/json" }); res.end(JSON.stringify(json)); };

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/__knobs") {
    let b = ""; for await (const c of req) b += c;
    knobs = { ...knobs, ...JSON.parse(b || "{}") };
    return send(res, 200, knobs);
  }
  if (url.pathname === "/__stats") {
    const out = { ...stats, knobs, seconds: (Date.now() - stats.since) / 1000 };
    if (url.searchParams.get("reset")) Object.assign(stats, { calls: 0, results: {}, peak: stats.inFlight, since: Date.now() });
    return send(res, 200, out);
  }
  if (url.pathname === "/__last") {
    const since = Number(url.searchParams.get("since") ?? 0);
    return send(res, 200, [...lastCall].filter(([, t]) => t >= since).map(([sn, t]) => ({ sn, t })));
  }
  stats.calls++; stats.inFlight++; stats.peak = Math.max(stats.peak, stats.inFlight);
  const done = (status, json, kind) => {
    stats.inFlight--; stats.results[kind] = (stats.results[kind] ?? 0) + 1; send(res, status, json);
  };
  const sn = /\/(L[TS]\d+[A-Z])\b/.exec(url.pathname)?.[1];
  if (sn) lastCall.set(sn, Date.now());
  let body = "";
  if (req.method === "POST") for await (const c of req) body += c;
  const r = Math.random();
  if (r < 0.001) { await sleep(10000 + Math.random() * 1000); return done(504, { msg: "gateway timeout" }, "504"); }
  if (knobs.outage) { await sleep(latency()); return done(503, { msg: "unavailable" }, "503"); }
  if (r < 0.001 + knobs.r429) { await sleep(50); return done(429, { msg: "Throttled" }, "429"); }
  const slow = r < 0.001 + knobs.r429 + knobs.slow;
  await sleep(slow ? knobs.slowMs[0] + Math.random() * (knobs.slowMs[1] - knobs.slowMs[0]) : latency());
  const out = handle({ method: req.method, path: url.pathname, query: url.searchParams, auth: req.headers.authorization || "", body });
  done(out.status, out.json, slow ? "slow" : String(out.status));
}).listen(PORT, () => console.log(`fake SunSynk :${PORT}, fleet ${shape}: ${f.logins.length} logins${f.share ? " + share" : ""}`));
