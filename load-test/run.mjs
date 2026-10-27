// SOLAR-209 load test runner. Writes one fake minute per inverter per minute the
// way `poll` does (poll_jobs, inverters_cached, poll_commit, detectors every 10th
// minute, email_poll_step), times each minute batch and the page readers for one
// plant, and samples the database container's CPU, memory and swap.
//
//   node load-test/run.mjs --inverters 200 --minutes 10 --out /path/200.jsonl
//
// Needs the containers from load-test/README.md. Never point it at prod: it only
// talks to the container named in DB, through the client container.
import { spawn, execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";

const arg = (k, d) => {
  const i = process.argv.indexOf(`--${k}`);
  return i > 0 ? process.argv[i + 1] : d;
};
const INVERTERS = Number(arg("inverters", 50));
const MINUTES = Number(arg("minutes", 10));
const WORKERS = Number(arg("workers", 10)); // ~ PostgREST's pool on Micro
const SHARDS = 2;
const OUT = arg("out", null);
const DB = "solar-loadtest-db";
const CLIENT = "solar-loadtest-client";
const PAGE_PLANT = 900001;

const sh = (cmd, args) => execFileSync(cmd, args, { encoding: "utf8" }).trim();
const sql = (q) => sh("docker", ["exec", CLIENT, "psql", "-h", DB, "-U", "postgres", "-Atq", "-c", q]);
const lit = (v) => `'${JSON.stringify(v).replaceAll("'", "''")}'::jsonb`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// One psql session = one pooled connection. run() resolves when the batch is through.
function worker() {
  const p = spawn("docker", ["exec", "-i", CLIENT, "psql", "-h", DB, "-U", "postgres", "-Atq"]);
  let buf = "", waiting = null, errors = 0;
  p.stdout.on("data", (d) => {
    buf += d;
    if (waiting && buf.includes("__DONE__")) { buf = ""; const w = waiting; waiting = null; w(); }
  });
  p.stderr.on("data", (d) => { if (/ERROR/.test(d)) { errors++; if (errors <= 3) process.stderr.write(d); } });
  return {
    run(text) {
      return new Promise((res) => { waiting = res; p.stdin.write(text + "\n\\echo __DONE__\n"); });
    },
    get errors() { return errors; },
    end() { p.stdin.end(); },
  };
}

function readingRow(sn, plantId, ts) {
  const hour = ((ts + 7200) % 86400) / 3600; // SAST
  const pv = Math.max(0, Math.round(5000 * Math.sin(Math.PI * (hour - 6) / 12))) + Math.round(Math.random() * 50);
  const load = 1200 + Math.round(Math.random() * 300);
  return {
    ts, sn, plant_id: plantId, status: 1, device_time: new Date(ts * 1000).toISOString().slice(0, 19).replace("T", " "),
    pv_w: pv, pv_today_kwh: 10, pv_total_kwh: 5000, batt_power_w: 800 - pv / 3, batt_w: 800 - pv / 3,
    batt_soc: 60, batt_voltage_v: 52, batt_current_a: -10, batt_temp_c: 25, batt_chg_today_kwh: 3,
    batt_dischg_today_kwh: 4, batt_chg_total_kwh: 900, batt_dischg_total_kwh: 950, grid_w: 200,
    grid_import_today_kwh: 2, grid_export_today_kwh: 0, grid_import_total_kwh: 800, grid_export_total_kwh: 0,
    grid_freq_hz: 50, grid_pf: 1, grid_volt_v: 230, grid_relay_status: "ON", load_w: load, load_today_kwh: 15,
    load_total_kwh: 7000, load_freq_hz: 50, output_w: load - 100, output_volt_v: 230, output_freq_hz: 50,
    carried: false,
  };
}

function accountSql(a, ts, refresh) {
  const readings = a.sns.map((sn) => readingRow(sn, a.plant, ts));
  const strings = a.sns.flatMap((sn, i) => [1, 2].map((no) => ({
    ts, sn, no, plant_id: a.plant, volt_v: 350, current_a: readings[i].pv_w / 700, power_w: readings[i].pv_w / 2, today_kwh: 5,
  })));
  const sum = (k) => readings.reduce((s, r) => s + r[k], 0);
  const agg = [{ plant_id: a.plant, pv_w: sum("pv_w"), load_w: sum("load_w"), batt_w: Math.round(sum("batt_w")), grid_w: sum("grid_w"), soc: 60 }];
  const meta = a.sns.map((sn, i) => ({
    sn, updated_ts: ts, alias: sn, model: "SUN-8K", soft_ver: "1", hmi_ver: "1", gsn: sn, comm_type: "wifi",
    capacity_ah: 200, number_of_batteries: 1, plant_id: a.plant, plant_name: `Load test`, ord: i, status: 1,
  }));
  const invs = a.sns.map((sn) => ({ sn, plant_id: a.plant, account_id: a.account }));
  let s = `select count(*) from public.inverters_cached('${a.account}');\n` +
    `select public.poll_commit('${a.account}', ${ts}, ${lit(readings)}, ${lit(strings)}, ${lit(agg)}, ${lit(meta)}, ${lit(invs)}, 'fake-token', 4102444800);\n`;
  if (refresh) s += `select public.plant_features_detect(${a.plant}); select public.battery_banks_detect(p_plant => ${a.plant});\n`;
  return s;
}

function sample() {
  const [cpu, mem] = sh("docker", ["stats", "--no-stream", "--format", "{{.CPUPerc}}|{{.MemUsage}}", DB]).split("|");
  const swap = Number(sh("docker", ["exec", DB, "cat", "/sys/fs/cgroup/memory.swap.current"]));
  const toMb = (m) => { const [, n, u] = m.match(/([\d.]+)\s*(\w+)/); return Number(n) * ({ B: 1 / 1048576, KiB: 1 / 1024, MiB: 1, GiB: 1024 }[u] ?? 1); };
  return { cpu: parseFloat(cpu), memMb: Math.round(toMb(mem.split("/")[0])), swapMb: Math.round(swap / 1048576) };
}

const ownerSql = (plant) => `begin;
select set_config('request.jwt.claim.sub', (select user_id::text from public.plant_users where plant_id = ${plant}), true);
select set_config('request.jwt.claims', json_build_object('sub', (select user_id from public.plant_users where plant_id = ${plant}), 'role', 'authenticated')::text, true);
set local role authenticated;
select 'PAGES ' || loadtest.time_pages(${plant})::text;
commit;`;

async function main() {
  const accounts = JSON.parse(sql(`select coalesce(json_agg(json_build_object('plant', pu.plant_id, 'account', pu.account_id,
      'sns', array['LT' || pu.plant_id || 'A', 'LT' || pu.plant_id || 'B']) order by pu.plant_id), '[]')
    from public.plant_users pu where pu.plant_id between 900001 and ${900000 + INVERTERS / 2}`));
  if (accounts.length * 2 !== INVERTERS) throw new Error(`fleet has ${accounts.length * 2} inverters, wanted ${INVERTERS}: run loadtest.add_fleet first`);
  const pool = Array.from({ length: WORKERS }, worker);
  let pageOut = "";
  const samples = [];
  let sampling = true;
  (async () => { while (sampling) { try { samples.push(sample()); } catch {} await sleep(3000); } })();

  const rows = [];
  for (let m = 0; m < MINUTES; m++) {
    const now = Date.now() / 1000;
    const ts = Math.floor(now / 60) * 60 + 60; // next minute boundary, as cron fires
    await sleep((ts - now) * 1000);
    const refresh = (ts / 60) % 10 === 0;
    const t0 = performance.now();
    const pagesP = sleep(3000).then(async () => {
      const p0 = performance.now();
      const res = await new Promise((done) => {
        const p = spawn("docker", ["exec", "-i", CLIENT, "psql", "-h", DB, "-U", "postgres", "-Atq"]);
        let o = ""; p.stdout.on("data", (d) => (o += d)); p.on("close", () => done(o)); p.stdin.end(ownerSql(PAGE_PLANT));
      });
      const line = res.split("\n").find((l) => l.startsWith("PAGES "));
      return { pagesMs: line ? JSON.parse(line.slice(6)) : null, pagesWallMs: Math.round(performance.now() - p0) };
    });
    const shardRuns = [];
    for (let s = 0; s < SHARDS; s++) {
      const mine = accounts.filter((_, i) => i % SHARDS === s);
      const ws = pool.filter((_, i) => i % SHARDS === s);
      shardRuns.push((async () => {
        await ws[0].run(`select count(*) from public.poll_jobs(${s}, ${SHARDS});`);
        await Promise.all(ws.map((w, wi) => w.run(mine.filter((_, i) => i % ws.length === wi).map((a) => accountSql(a, ts, refresh)).join(""))));
        const outcomes = mine.map((a) => ({ account: a.account, outcome: "ok" }));
        await ws[0].run(`select public.email_poll_step(${ts}, ${lit(outcomes)}, array[${mine.map((a) => a.plant).join(",")}]::bigint[]);`);
      })());
    }
    await Promise.all(shardRuns);
    const batchMs = Math.round(performance.now() - t0);
    const pages = await pagesP;
    const errors = pool.reduce((s, w) => s + w.errors, 0);
    const row = { inverters: INVERTERS, minute: m + 1, ts, refresh, batchMs, ...pages, errors, at: samples.at(-1) };
    rows.push(row);
    console.log(JSON.stringify(row));
    if (OUT) appendFileSync(OUT, JSON.stringify(row) + "\n");
  }
  sampling = false;
  pool.forEach((w) => w.end());
  const max = (xs) => Math.max(...xs);
  const avg = (xs) => Math.round(xs.reduce((a, b) => a + b, 0) / xs.length);
  const pageMax = (r) => (r.pagesMs ? max(Object.values(r.pagesMs)) : Infinity);
  const summary = {
    summary: true, inverters: INVERTERS, minutes: MINUTES,
    batchAvgMs: avg(rows.map((r) => r.batchMs)), batchMaxMs: max(rows.map((r) => r.batchMs)),
    pageMaxMs: max(rows.map(pageMax)), pageAvgMs: avg(rows.map(pageMax)),
    cpuAvg: avg(samples.map((s) => s.cpu)), cpuMax: max(samples.map((s) => s.cpu)),
    memMaxMb: max(samples.map((s) => s.memMb)), swapMaxMb: max(samples.map((s) => s.swapMb)),
    errors: rows.at(-1).errors,
  };
  console.log(JSON.stringify(summary));
  if (OUT) appendFileSync(OUT, JSON.stringify(summary) + "\n");
}

main().catch((e) => { console.error(e); process.exit(1); });
