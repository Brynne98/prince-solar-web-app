// `poll-lane` — poller v3 stage 1 (SOLAR-656; design reports/poller-v3-design.md, 2, 5, 7).
//
// While private.poll_mode is 'lanes' (0259), pg_cron posts {lane, lanes, ts} once a minute
// for each of K lanes. A lane answers at once and reads in the background
// (EdgeRuntime.waitUntil): it owns the read seconds s with s % lanes = lane, and at each of
// them starts the reads due that second (0258's read_second: a login's second, or a plant's
// for a login read plant by plant). So the fleet is read evenly over the minute.
//
//   routes     poll_lane_routes every 10 s: the full list for the lane's seconds, each with
//              ends_at (when the clock alone may end its reading) and the plant version.
//   a read     readAccount (_shared/poller.ts) for one login's plants due that second, with
//              the version it started on. Not started 20 s after its second: skipped. Not
//              done 50 s after its second, or at ends_at: dropped. Either way counted lost;
//              recover refills it.
//   calls      at most `cap` SunSynk calls in flight in the lane, cap = calls/s x p99 latency
//              x 1.5 (Little's law), halved for 30 s when over 20% of the last 10 s's calls
//              timed out, failed or got a 5xx. A 429 backs off that login only (sunsynk.ts).
//   saves      poll_commit_batch once a second over one direct connection (_shared/pgdb.ts):
//              every read finished since the last one. A deadlock is retried once; any other
//              error saves login by login, so a bad row costs its login only. Then
//              email_poll_step for the batch. A plant the save refused is not read again
//              this run.
//   at the end one sunsynk_tally (calls, shard = lane) and one poll_run_log row.
//
// Chores (own cron jobs since 0259): {chore: "share_retry"} every minute,
// {chore: "calls_report"} at 00:05, 00:10 and 00:15 SA time.
import { flushErrors, noteError, reportError, serve, track } from "../_shared/errors.ts";
import { rpc, useDb } from "../_shared/db.ts";
import { directDb } from "../_shared/pgdb.ts";
import {
  type Account,
  denyUnlessServer,
  getInverters,
  type PlantJob,
  saveCallTally,
  setFleetCap,
  shareAccount,
  watchCalls,
} from "../_shared/sunsynk.ts";
import type { InverterInfo } from "../_shared/extract.ts";
import {
  accountFailed,
  type AccountResult,
  type Committed,
  type CommitRow,
  emailOutcome,
  readAccount,
} from "../_shared/poller.ts";

const START_LATE_MS = 20_000;
const HARD_DEADLINE_MS = 50_000;
const ROUTES_EVERY_MS = 10_000;
const SAVE_EVERY_MS = 1_000;
/** a minute not saved by then is left to recover: keeps a lane well inside the 400 s wall limit */
const SAVE_UNTIL_MS = 120_000;
/** a lane call that arrives this late reads nothing: the next minute's lanes are on their way */
const TOO_LATE_MS = 30_000;

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, Math.max(0, ms)));
const background = (p: Promise<unknown>) => (globalThis as any).EdgeRuntime?.waitUntil?.(p);

// One direct connection per isolate, the handle every shared read and save goes through.
const DB_URL = Deno.env.get("POLLER_DB_URL") ?? Deno.env.get("SUPABASE_DB_URL") ?? "";
let handleSet = false;
function directHandle() {
  if (!handleSet) {
    if (!DB_URL) throw new Error("poll-lane: no POLLER_DB_URL or SUPABASE_DB_URL");
    useDb(directDb(DB_URL));
    handleSet = true;
  }
}

// ---------------------------------------------------------------------------
// The cap on calls in flight, from the calls of the last seconds.
// ---------------------------------------------------------------------------
const CAP_MIN = 20, CAP_MAX = 600, CAP_START = 100;
const calls: { at: number; ms: number; bad: boolean }[] = [];
let cap = CAP_START, shrunkUntil = 0;
watchCalls((ms, result) => calls.push({ at: Date.now(), ms, bad: result === "timeout" || result === "network" || result === "5xx" }));

function resizeCap(now: number) {
  while (calls.length && calls[0].at < now - 30_000) calls.shift();
  const recent = calls.filter((c) => c.at >= now - 10_000);
  const bad = recent.filter((c) => c.bad).length;
  if (bad >= 10 && bad > recent.length * 0.2) {
    if (now >= shrunkUntil) cap = Math.max(CAP_MIN, Math.floor(cap / 2));
    shrunkUntil = now + 30_000;
  } else if (now >= shrunkUntil && calls.length >= 20) {
    const ms = calls.slice(-2000).map((c) => c.ms).sort((a, b) => a - b);
    const p99 = ms[Math.min(ms.length - 1, Math.floor(ms.length * 0.99))] / 1000;
    const perS = recent.length / 10;
    cap = Math.min(CAP_MAX, Math.max(CAP_MIN, Math.ceil(perS * p99 * 1.5)));
  }
  setFleetCap(cap);
}

// ---------------------------------------------------------------------------
// One lane, one minute.
// ---------------------------------------------------------------------------
type Route = {
  plant_id: number; account_id: string; plant_version: number | null; timezone: string;
  batt_positive_means: string | null; has_grid: boolean | null; ends_at: string | null; read_second: number;
  user_id: string; sunsynk_username: string; access_token: string | null; access_expires_at: number | null; lead: boolean;
};
type Done = { acc: Account; second: number; result: AccountResult; row: CommitRow | null; finish: (c: Committed) => Promise<AccountResult> };
type Stats = {
  reads: number; plants: number; lostLate: number; lostDeadline: number; lostEnded: number; lostSave: number; failed: number;
  saved: number; refused: number; batches: number; splits: number; deadlocks: number; saveMs: number[]; maxCap: number;
};

async function runLane(lane: number, lanes: number, ts: number): Promise<void> {
  const t0 = ts * 1000;
  const started = Date.now();
  const seconds = Array.from({ length: 60 }, (_, s) => s).filter((s) => s % lanes === lane);
  const st: Stats = { reads: 0, plants: 0, lostLate: 0, lostDeadline: 0, lostEnded: 0, lostSave: 0, failed: 0, saved: 0, refused: 0,
    batches: 0, splits: 0, deadlocks: 0, saveMs: [], maxCap: cap };
  const accounts = new Map<string, Account>();
  const refused = new Set<number>();
  const results: { r: AccountResult; second: number }[] = [];
  const queue: Done[] = [];
  const reads: Promise<void>[] = [];
  const finishing: Promise<unknown>[] = [];
  let jobsRead: number | undefined;
  let error: string | undefined;

  // --- routes ---
  let routes: Route[] = [];
  let loadedAt = 0;
  let loading: Promise<void> | null = null;
  const loadRoutes = () => loading ??= rpc<Route[]>("poll_lane_routes", { p_seconds: seconds, p_at: new Date().toISOString() })
    .then((r) => { routes = r ?? []; loadedAt = Date.now(); jobsRead ??= loadedAt; })
    .catch((e) => {
      console.warn("poll_lane_routes:", e instanceof Error ? e.message : e);
      noteError("lane_routes_failed", e, { hourly: true });
    })
    .finally(() => { loading = null; });

  const accountOf = (r: Route): Account => {
    let a = accounts.get(r.account_id);
    if (!a) {
      a = { id: r.account_id, user_id: r.user_id, sunsynk_username: r.sunsynk_username,
            access_token: r.access_token, access_expires_at: r.access_expires_at == null ? null : Number(r.access_expires_at) };
      accounts.set(a.id, a);
    } else if (r.access_token && Number(r.access_expires_at ?? 0) > Number(a.access_expires_at ?? 0)) {
      a.access_token = r.access_token;          // renewed by another lane since
      a.access_expires_at = Number(r.access_expires_at);
    }
    return a;
  };
  const jobOf = (r: Route, acc: Account): PlantJob => ({
    plantId: Number(r.plant_id), plantName: null, timezone: r.timezone, battPositiveMeans: r.batt_positive_means,
    backfillNext: null, backfillUntil: null, backfillTries: 0, tempNext: null, tempTries: 0,
    hasGrid: r.has_grid, version: r.plant_version == null ? null : Number(r.plant_version), account: acc,
  });

  // --- one second's reads ---
  const begun = new Set<number>();   // a plant moved to a later second by a newer list is not read twice
  const lists = new Map<string, Promise<InverterInfo[]>>();   // one live inverter list per login and run
  const ended = (r: Route) => r.ends_at != null && Date.parse(r.ends_at) <= Date.now();
  const dueAt = (s: number) => routes.filter((r) => r.read_second === s && !refused.has(Number(r.plant_id)) && !begun.has(Number(r.plant_id)));

  async function startSecond(s: number) {
    const at = t0 + s * 1000;
    let due = dueAt(s);
    if (!due.length) return;
    if (Date.now() > at + START_LATE_MS) { st.lostLate += due.length; return; }
    // past its end by the list: the list may be 10 s old and ends_at early, so ask once more
    if (due.some(ended)) { await loadRoutes(); due = dueAt(s); }
    const live = due.filter((r) => !ended(r));
    st.lostEnded += due.length - live.length;
    if (!live.length) return;
    for (const r of live) begun.add(Number(r.plant_id));
    // one read per login and end time, so a seat that closes stops its own plant only
    const groups = new Map<string, Route[]>();
    for (const r of live) groups.set(`${r.account_id} ${r.ends_at}`, [...(groups.get(`${r.account_id} ${r.ends_at}`) ?? []), r]);
    let cached = new Map<string, InverterInfo[]>();
    try {
      cached = await cachedInverters([...new Set(live.map((r) => r.account_id))], live.map((r) => Number(r.plant_id)));
    } catch (e) {
      console.warn("inverters_cached_many:", e instanceof Error ? e.message : e);   // each read reads its own
    }
    if (Date.now() > at + START_LATE_MS) { st.lostLate += live.length; return; }
    for (const rs of groups.values()) {
      const endsAt = rs[0].ends_at ? Date.parse(rs[0].ends_at) : Infinity;
      st.reads++;
      st.plants += rs.length;
      reads.push(readOne(rs, s, Math.min(at + HARD_DEADLINE_MS, endsAt), endsAt,
        cached.get(rs[0].account_id)?.filter((c) => rs.some((r) => Number(r.plant_id) === c.plantId))));
    }
  }

  async function readOne(rs: Route[], second: number, stopAt: number, endsAt: number, cached: InverterInfo[] | undefined) {
    const shared = accountOf(rs[0]);
    // this read's view of the login: its own stop signal, the token shared with the login's other reads
    const ctl = new AbortController();
    const acc: Account = Object.create(shared, {
      signal: { value: ctl.signal },
      access_token: { get: () => shared.access_token, set: (v) => { shared.access_token = v; } },
      access_expires_at: { get: () => shared.access_expires_at, set: (v) => { shared.access_expires_at = v; } },
    });
    const jobs = rs.map((r) => jobOf(r, acc));
    const liveList = () => {
      let p = lists.get(shared.id);
      if (!p) {
        p = getInverters(shared);
        p.catch(() => lists.delete(shared.id));
        lists.set(shared.id, p);
      }
      return p;
    };
    let timer: number | undefined;
    const stop = new Promise<"stop">((go) => { timer = setTimeout(() => go("stop"), Math.max(0, stopAt - Date.now())); });
    const reading = readAccount(acc, jobs, ts, { cached, lead: rs.some((r) => r.lead), liveList });
    reading.catch(() => {});   // a dropped read's late failure is nobody's
    try {
      const got = await Promise.race([reading, stop]);
      if (got === "stop") {
        ctl.abort();
        if (stopAt >= endsAt) st.lostEnded += jobs.length; else st.lostDeadline += jobs.length;
        return;
      }
      if (!got.row) results.push({ r: got.result, second });
      queue.push({ acc: shared, second, ...got });
    } catch (e) {
      st.failed++;
      const r = await accountFailed(shared, jobs, e);
      results.push({ r, second });
      queue.push({ acc: shared, second, result: r, row: null, finish: async () => r });
    } finally {
      clearTimeout(timer);
    }
  }

  // --- saves, once a second ---
  // A timeout or a lost connection is the database's, not one login's: the batch is tried once
  // more, not split. Anything else splits it, so a bad row costs its own login only.
  const dbDown = (e: any) => e?.code === "57014" || e?.code == null || String(e.code).startsWith("08") || /CONNECT/.test(String(e.code));
  async function saveRows(items: Done[]): Promise<(Committed | Error)[]> {
    const call = () => rpc<{ i: number; account: string; result: Committed }[]>("poll_commit_batch",
      { p_ts: ts, p_rows: items.map((d) => d.row) });
    let out: { i: number; result: Committed }[] | null = null;
    let err: any;
    try { out = await call(); } catch (e) { err = e; }
    if (!out && (err?.code === "40P01" || dbDown(err)) && Date.now() < t0 + SAVE_UNTIL_MS) {
      if (err?.code === "40P01") st.deadlocks++;
      try { out = await call(); } catch (e) { err = e; }
    }
    if (out) {
      const byI = new Map(out.map((o) => [Number(o.i), o.result]));
      return items.map((_, k) => byI.get(k + 1) ?? new Error("poll_commit_batch: no answer for this login"));
    }
    const failed = err instanceof Error ? err : new Error(String(err));
    if (items.length === 1 || dbDown(err) || err?.code === "40P01") return items.map(() => failed);
    st.splits++;
    console.warn(`poll_commit_batch: ${items.length} logins saved one by one:`, failed.message);
    const each: (Committed | Error)[] = [];
    for (const d of items) each.push(...await saveRows([d]));
    return each;
  }

  async function flush() {
    const items = queue.splice(0);
    if (!items.length) return;
    // a minute saved this late is left to recover (and keeps the lane inside its time)
    const tooLate = Date.now() > t0 + SAVE_UNTIL_MS;
    const rows = items.filter((d) => d.row && !tooLate);
    if (tooLate) st.lostSave += items.filter((d) => d.row).reduce((n, d) => n + Object.keys(d.row!.versions).length, 0);
    const answers = rows.length ? await saveRows(rows) : [];
    const now = Date.now();
    const written = new Set<number>();
    for (const [k, d] of rows.entries()) {
      const a = answers[k];
      if (a instanceof Error) {
        st.failed++;
        d.result = await accountFailed(d.acc, Object.keys(d.row!.versions).map((p) => ({ plantId: Number(p) })), a);
        results.push({ r: d.result, second: d.second });
        continue;
      }
      for (const p of a.refused ?? []) refused.add(Number(p));
      st.refused += a.refused?.length ?? 0;
      st.saved += a.plants.length;
      for (const p of a.plants) written.add(Number(p));
      st.saveMs.push(now - (t0 + d.second * 1000));
      // sets the result's counts at once, then detection and temperatures in the background
      finishing.push(d.finish(a).then((r) => results.push({ r, second: d.second })).catch(() => {}));
    }
    if (rows.length) st.batches++;
    // one outcome per login: a login read plant by plant counts as read when any plant was
    const rank = { ok: 3, sunsynk: 2, ours: 1 } as Record<string, number>;
    const byLogin = new Map<string, { account: string; outcome: string }>();
    for (const o of items.filter((d) => !(d.row && tooLate)).map((d) => emailOutcome(d.result))) {
      if (o && (rank[o.outcome] ?? 0) > (rank[byLogin.get(o.account)?.outcome ?? ""] ?? 0)) byLogin.set(o.account, o);
    }
    const step = () => rpc("email_poll_step", { p_ts: ts, p_outcomes: [...byLogin.values()], p_plants: [...written] });
    try {
      const stepped = await step().catch((e) => (e?.code === "40P01" ? step() : Promise.reject(e))) as any;
      if (stepped?.failed?.length) throw new Error(`email_poll_step: ${stepped.failed.length} failed`);
    } catch (e) {
      console.warn("email_poll_step:", e instanceof Error ? e.message : e);
      noteError("email_step_failed", e, { hourly: true });
    }
  }

  let finishedReading = false;
  let saving: Promise<void> = Promise.resolve();
  try {
    directHandle();
    await loadRoutes();
    saving = (async () => {
      // saves until every read is done and nothing waits
      for (let open = true; open;) {
        const tick = Date.now();
        open = !finishedReading || queue.length > 0;
        await flush().catch((e) => console.warn("flush:", e instanceof Error ? e.message : e));
        resizeCap(Date.now());
        st.maxCap = Math.max(st.maxCap, cap);
        if (open) await sleep(SAVE_EVERY_MS - (Date.now() - tick));
      }
    })();
    for (const s of seconds) {
      await sleep(t0 + s * 1000 - Date.now());
      if (Date.now() - loadedAt >= ROUTES_EVERY_MS) background(loadRoutes());
      await startSecond(s);
    }
    await Promise.all(reads);
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
    await reportError("poll-lane", e);
  } finally {
    finishedReading = true;
    await saving;
    await Promise.all(finishing);
  }

  const ms = st.saveMs.sort((a, b) => a - b);
  const q = (p: number) => (ms.length ? ms[Math.min(ms.length - 1, Math.floor(ms.length * p))] : null);
  const summary = {
    lane, lanes, ts, reads: st.reads, plants: st.plants, saved: st.saved, refused: st.refused, failed: st.failed,
    lost: { late: st.lostLate, deadline: st.lostDeadline, ended: st.lostEnded, save: st.lostSave },
    batches: st.batches, splits: st.splits, deadlocks: st.deadlocks, cap, max_cap: st.maxCap,
    save_ms: { p50: q(0.5), p95: q(0.95), max: ms.at(-1) ?? null }, wall_ms: Date.now() - started,
  };
  console.log("lane", JSON.stringify(summary));
  try {
    await saveCallTally({ shard: lane, ms: Date.now() - started, plants: st.plants });
    await rpc("poll_run_log", { p: {
      ts, shard: lane, shards: lanes, scheduled_ms: t0, started_ms: started, jobs_read_ms: jobsRead ?? null,
      finished_ms: Date.now(), plants: st.plants,
      inverters: results.reduce((n, x) => n + x.r.inverters, 0),
      logins: [{ lane: summary }, ...results.map(({ r, second }) => ({
        account: r.account, second, commit_ms: r.commitMs ?? null, plants: r.plants.length,
        inverters: r.inverters, error: r.error?.slice(0, 300) ?? null,
      }))],
      error: error ?? (st.failed ? `${st.failed} reads failed` : null),
    } });
  } catch (e) {
    console.warn("poll_run_log:", e instanceof Error ? e.message : e);
    noteError("run_log_failed", e, { hourly: true });
  }
  await flushErrors("poll-lane");
}

async function cachedInverters(accounts: string[], plants: number[]): Promise<Map<string, InverterInfo[]>> {
  const rows = await rpc<any[]>("inverters_cached_many", { p_accounts: accounts, p_plants: plants });
  const out = new Map<string, InverterInfo[]>(accounts.map((a) => [a, []]));
  for (const r of rows ?? []) {
    out.get(r.account_id)?.push({
      sn: r.sn, alias: r.alias ?? r.sn, plantId: r.plant_id == null ? undefined : Number(r.plant_id),
      plantName: r.plant_name ?? undefined, model: r.model ?? undefined, status: r.status ?? undefined,
      gsn: r.gsn ?? undefined, soft: r.soft_ver ?? undefined, hmi: r.hmi_ver ?? undefined, commType: r.comm_type ?? undefined,
      lastReading: r.last_reading ?? null, carriedRun: Number(r.carried_run) || 0,
      uploadS: r.upload_s == null ? null : Number(r.upload_s),
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Chores
// ---------------------------------------------------------------------------

// SunSynk refused the share login: try the secret again an hour after the last try, so
// shared plants restart without an owner pressing Check (SOLAR-451).
async function retryShareLogin() {
  try {
    const id = await rpc<string | null>("share_retry_due");   // 0177
    if (!id) return;
    try {
      if (await shareAccount()) console.log("share login: signed in again");
    } catch (e) {
      // Logged as another stop, which the next try is timed from. Already stopped, so no email.
      const msg = e instanceof Error ? e.message : String(e);
      await rpc("account_mark", { p_account: id, p_status: "needs_relink", p_error: msg });
      console.warn("share login retry failed:", msg);
      noteError("share_login_retry_failed", e, { hourly: true });
    }
  } catch (e) {
    console.warn("share login retry skipped:", e instanceof Error ? e.message : e);
    noteError("share_login_retry_skipped", e, { hourly: true });
  } finally {
    await saveCallTally();
  }
}

// SOLAR-468: yesterday's SunSynk calls to PostHog. Every send of a day has the same uuid and
// time, so PostHog keeps one; the repeats cover a send that failed.
async function callsReport() {
  try {
    const day = await rpc<Record<string, unknown> | null>("sunsynk_calls_report");
    if (day) await track("sunsynk_calls_counted", "edge:poll", String(day.day), `${day.day}T23:59:00+02:00`, { ...day, $process_person_profile: false });
  } catch (e) {
    console.warn("sunsynk_calls_report:", e instanceof Error ? e.message : e);
    noteError("calls_report_failed", e, { hourly: true });
  }
}

serve("poll-lane", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  if (body.chore === "share_retry") { await retryShareLogin(); return json({ ok: true, chore: body.chore }); }
  if (body.chore === "calls_report") { await callsReport(); return json({ ok: true, chore: body.chore }); }
  const lanes = Math.min(60, Math.max(1, Math.floor(Number(body.lanes) || 1)));
  const lane = Math.min(lanes - 1, Math.max(0, Math.floor(Number(body.lane) || 0)));
  const ts = Number(body.ts) || Math.floor(Date.now() / 60000) * 60;
  if (Date.now() - ts * 1000 > TOO_LATE_MS) return json({ ok: false, lane, lanes, ts, error: "too late for its minute" }, 409);
  background(runLane(lane, lanes, ts));
  return json({ ok: true, lane, lanes, ts }, 202);
});
