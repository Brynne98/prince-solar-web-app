// Poller v3 load test driver (SOLAR-656). LOCAL stack only. Plays pg_cron: each minute it
// reads private.poll_mode and posts the K lanes (mode 'lanes') or today's poll shards
// (mode 'edge'), as 0259's cron jobs do. It records the plants due each minute
// (lt3.expected), samples database connections every second and the edge container's CPU
// every minute, runs the scenario's steps, and prints one JSON result at the end.
//
//   npx deno@2.5.6 run -A --node-modules-dir=none load-test/v3/drive.ts '<json options>'
//   options: {label, minutes, mode: "lanes"|"edge", lanes, db, api, key, mock, edge_container,
//             warm (first minutes left out of the counts, default 1: a new fleet reads its
//             inverter lists then), steps: [{minute, knobs?, mode?, sql?, stall_s?}]}
//   steps run at the start of their minute (0 = the first minute); sql runs on its own
//   connection; stall_s holds an exclusive lock on agg_minute and readings that long.
import postgres from "npm:postgres@3.4.5";

const o = JSON.parse(Deno.args[0] ?? "{}");
const sql = postgres(o.db, { max: 3, onnotice: () => {} });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, Math.max(0, ms)));
const mock = (path: string, body?: unknown) =>
  fetch(`${o.mock}${path}`, body ? { method: "POST", body: JSON.stringify(body) } : {}).then((r) => r.json());

async function cpuUsec(): Promise<number> {
  const out = await new Deno.Command("docker", { args: ["exec", o.edge_container, "cat", "/sys/fs/cgroup/cpu.stat"] }).output();
  return Number(/usage_usec (\d+)/.exec(new TextDecoder().decode(out.stdout))?.[1] ?? 0);
}

await sql`update private.poll_mode set mode = ${o.mode}, lanes = ${o.lanes ?? 4}, changed_at = now()`;
const first = Math.floor(Date.now() / 60000) * 60 + 60;   // the next whole minute
let peakConn = 0, peakActive = 0;
const conns: number[] = [];
let sampling = true;
const sampler = (async () => {
  while (sampling) {
    const [r] = await sql`select count(*)::int as n, count(*) filter (where state = 'active')::int as a
                            from pg_stat_activity where datname = 'postgres' and backend_type = 'client backend'`;
    peakConn = Math.max(peakConn, r.n); peakActive = Math.max(peakActive, r.a); conns.push(r.n);
    await sleep(1000);
  }
})();

const posts: Promise<unknown>[] = [];
const perMinute: { ts: number; mode: string; cpu_ms: number; calls: number }[] = [];
await sleep(first * 1000 - Date.now() - 1500);
await mock("/__stats?reset=1");
let cpu0 = await cpuUsec(), calls0 = 0;
for (let m = 0; m < o.minutes; m++) {
  const ts = first + m * 60;
  // a minute's steps run just before its boundary (a stall holds its lock before the lanes go)
  await sleep(ts * 1000 - 300 - Date.now());
  for (const s of (o.steps ?? []).filter((s: any) => s.minute === m)) {
    if (s.knobs) await mock("/__knobs", s.knobs);
    if (s.mode) await sql`update private.poll_mode set mode = ${s.mode}`;
    if (s.sql) await sql.unsafe(s.sql);
    if (s.stall_s) {
      let held!: () => void;
      const locked = new Promise<void>((r) => { held = r; });
      posts.push(sql.begin(async (tx) => {
        await tx`lock table public.agg_minute, public.readings in access exclusive mode`;
        held();
        await sleep(s.stall_s * 1000);
      }));
      await locked;
    }
  }
  await sleep(ts * 1000 - Date.now());
  const [pm] = await sql`select mode, lanes from private.poll_mode`;
  const headers = { Authorization: `Bearer ${o.key}`, "Content-Type": "application/json" };
  if (pm.mode === "lanes") {
    for (let l = 0; l < pm.lanes; l++) {
      posts.push(fetch(`${o.api}/functions/v1/poll-lane`, { method: "POST", headers, body: JSON.stringify({ lane: l, lanes: pm.lanes, ts }),
        signal: AbortSignal.timeout(55000) }).then((r) => r.text()).catch(() => {}));
    }
  } else {
    const shards = await sql`select * from private.poll_shards()`;
    for (const s of shards) {
      posts.push(fetch(`${o.api}/functions/v1/poll`, { method: "POST", headers,
        body: JSON.stringify({ shard: s.shard, shards: s.shards, delay_ms: s.delay_ms }), signal: AbortSignal.timeout(55000) })
        .then((r) => r.text()).catch(() => {}));
    }
  }
  // the plants due this minute, as the routes stand now
  await sql`insert into lt3.expected (ts, plant_id, read_second)
            select ${ts}, plant_id, read_second from public.poll_routes(array(select generate_series(0, 59)), now())
            on conflict do nothing`;
  const cpu = await cpuUsec();
  const st = await mock("/__stats");
  perMinute.push({ ts, mode: pm.mode, cpu_ms: Math.round((cpu - cpu0) / 1000), calls: st.calls - calls0 });
  cpu0 = cpu; calls0 = st.calls;
}
// let the last minute's reads and saves finish (50 s deadline + saves)
await sleep(first * 1000 + o.minutes * 60000 + 75000 - Date.now());
const cpuEnd = await cpuUsec();
const stEnd = await mock("/__stats");
perMinute.push({ ts: first + o.minutes * 60, mode: "drain", cpu_ms: Math.round((cpuEnd - cpu0) / 1000), calls: stEnd.calls - calls0 });
sampling = false;
await sampler;
await Promise.allSettled(posts);

const last = first + (o.minutes - 1) * 60;
const from = first + (o.warm ?? 1) * 60;
const lost = await sql`select * from lt3.lost(${from}, ${last})`;
const exp = lost.reduce((n, r) => n + Number(r.expected), 0), lst = lost.reduce((n, r) => n + Number(r.lost), 0);
// second-to-save: lanes log each login's second; a shard read starts at its delay
const save = await sql`
  with l as (
    select r.minute, r.shard, x->>'second' as second, (x->>'commit_ms')::int as commit_ms,
           extract(epoch from r.scheduled_at - r.minute) * 1000 as delay_ms
      from private.poll_runs r, jsonb_array_elements(r.logins) x
     where r.minute between to_timestamp(${from}) and to_timestamp(${last}) and x ? 'commit_ms' and x->>'commit_ms' is not null)
  select count(*)::int as n,
         percentile_cont(0.5) within group (order by commit_ms - coalesce(second::int * 1000, delay_ms)) as p50,
         percentile_cont(0.95) within group (order by commit_ms - coalesce(second::int * 1000, delay_ms)) as p95,
         max(commit_ms - coalesce(second::int * 1000, delay_ms)) as max
    from l`;
const runErr = await sql`select coalesce(error, '') as error, count(*)::int as n from private.poll_runs
                          where minute between to_timestamp(${first}) and to_timestamp(${last}) and error is not null group by 1`;
const lanes = await sql`select x->'lane' as lane from private.poll_runs r, jsonb_array_elements(r.logins) x
                         where r.minute between to_timestamp(${from}) and to_timestamp(${last}) and x ? 'lane'`;
const laneLost = lanes.reduce((a, r) => {
  const l = r.lane.lost; a.late += l.late; a.deadline += l.deadline; a.ended += l.ended;
  a.splits += r.lane.splits; a.deadlocks += r.lane.deadlocks; a.failed += r.lane.failed; a.max_cap = Math.max(a.max_cap, r.lane.max_cap);
  return a;
}, { late: 0, deadline: 0, ended: 0, splits: 0, deadlocks: 0, failed: 0, max_cap: 0 });
const cpuMs = perMinute.reduce((n, m) => n + m.cpu_ms, 0);
const result = {
  label: o.label, mode: o.mode, lanes: o.lanes, minutes: o.minutes, first,
  plant_minutes: exp, lost: lst, lost_pct: exp ? Math.round(lst / exp * 10000) / 100 : null,
  lost_by_minute: lost.filter((r) => Number(r.lost) > 0).map((r) => [(Number(r.ts) - first) / 60, Number(r.lost)]),
  save_s: { n: save[0].n, p50: save[0].p50 / 1000, p95: save[0].p95 / 1000, max: save[0].max / 1000 },
  lane_counts: laneLost,
  db_connections: { peak: peakConn, peak_active: peakActive },
  sunsynk: { calls: stEnd.calls, per_s: Math.round(stEnd.calls / stEnd.seconds), peak_in_flight: stEnd.peak, results: stEnd.results },
  cpu: { total_ms: cpuMs, per_call_ms: stEnd.calls ? Math.round(cpuMs / stEnd.calls * 100) / 100 : null,
         per_minute_ms: perMinute.map((m) => m.cpu_ms) },
  run_errors: runErr,
};
console.log(JSON.stringify(result));
await sql.end();
Deno.exit(0);
