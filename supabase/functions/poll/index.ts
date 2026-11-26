// `poll` — the per-minute logger, sharded across linked accounts.
//
// pg_cron fires this every minute — once per SHARD (migration 0030). The request
// body carries {shard, shards, delay_ms}; this invocation keeps the accounts whose
// id hashes into its shard, waits delay_ms so the fleet is spread over the minute
// instead of hitting SunSynk at second zero, then polls its accounts in parallel.
// No body (local dev, manual invoke) means "every account, no delay".
//
// The set of plants to log comes from pollJobs() (0100, 0246), which returns only this
// shard's plants: since the billing switch-over, the plants billing.plant_state reads
// now, each through one working login. Jobs are grouped by account so each account's
// inverter list is fetched once. The commit (poll_commit_v2) writes only plants whose
// version is still the job's and that are still read, so a read that finishes after a
// switch or a delete writes nothing.
//
// Per account: fetch every inverter's realtime endpoints, map them with the shared
// extractReading(), and hand the whole minute (readings, per-string PV, metadata, a
// summed row per plant) to poll_commit(), which writes it in one transaction.
//
// Freshness gate (0032): `input` is fetched first. If its pvIV[0].time equals the
// device_time of the inverter's last stored row, the datalogger has not uploaded
// since, so the other four endpoints are skipped and the previous row's values are
// stored again under this minute, marked carried. See fetchInverter() in _shared/poller.ts.
//
// An account whose refresh token has died (password changed, token revoked) is
// marked needs_relink and skipped; the others continue. Any other per-account
// failure is recorded on the row and the account stays active for the next tick.
//
// Deliberately NOT ported: the gzipped `raw` payload table. It was 46 MB of the
// 96 MB SQLite file, has no dashboard consumer, and may embed account identifiers.
import { flushErrors, noteError, reportError, serve, track } from "../_shared/errors.ts";
import { heartbeat } from "../_shared/heartbeat.ts";
import { db, rpc } from "../_shared/db.ts";
import { denyUnlessServer } from "../_shared/server.ts";
import { type Account, saveAllCalls } from "../_shared/brands/index.ts";
import { ensureBootstrapAccount, type PlantJob, plantsToPoll, pollJobs, shareAccount } from "../_shared/plants.ts";
import { accountFailed, type AccountResult, emailOutcome, pollAccount } from "../_shared/poller.ts";

/** epoch seconds for the current minute — the dedup key for a sample */
const nowMinuteEpoch = () => Math.floor(Date.now() / 60000) * 60;

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// Sharding. The cron job (0030) decides how many invocations this minute needs
// and POSTs {shard, shards, delay_ms} to each. An account belongs to exactly one
// shard, chosen by a stable hash of its uuid, so no two isolates ever work the
// same account (or refresh the same token) in the same minute.
// ---------------------------------------------------------------------------
// account: poll only this account, now. Linking a plant sends it (plant_bootstrap_kick,
// 0094) so the first live reading lands at once instead of at the next minute.
type ShardSpec = { shard: number; shards: number; delayMs: number; account?: string };

const MAX_DELAY_MS = 30_000; // never eat more of the minute than the cron job planned for

async function shardSpec(req: Request): Promise<ShardSpec> {
  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const shards = Math.max(1, Math.floor(Number(body.shards) || 1));
  const shard = Math.min(shards - 1, Math.max(0, Math.floor(Number(body.shard) || 0)));
  const delayMs = Math.min(MAX_DELAY_MS, Math.max(0, Math.floor(Number(body.delay_ms) || 0)));
  const account = typeof body.account === "string" ? body.account : undefined;
  return { shard, shards, delayMs, account };
}

// SOLAR-468: this run's SunSynk calls into the daily tally, one write. A shard run also
// logs itself as a poll_run row (an empty shard too); a one-account run (Check) saves the
// calls only. At 00:05, 00:10 and 00:15 SA time shard 0 also sends yesterday's totals to
// PostHog. Every send of a day has the same uuid and time, so PostHog keeps one; the
// repeats cover a send that failed.
async function tallyCalls(spec: ShardSpec, runMs: number, plants: number, ts: number): Promise<void> {
  if (spec.account) return saveAllCalls();
  await saveAllCalls({ shard: spec.shard, ms: runMs, plants });
  const saMinute = Math.floor((ts + 2 * 3600) / 60) % 1440;
  if (spec.shard !== 0 || ![5, 10, 15].includes(saMinute)) return;
  try {
    const day = (await rpc("sunsynk_calls_report", {})) as Record<string, unknown> | null;
    if (day) await track("sunsynk_calls_counted", "edge:poll", String(day.day), `${day.day}T23:59:00+02:00`, { ...day, $process_person_profile: false });
  } catch (e) {
    console.warn("sunsynk_calls_report:", e instanceof Error ? e.message : e);
    noteError("calls_report_failed", e, { hourly: true });
  }
}

// SOLAR-650: one run-log row per shard run (0251). Never fails the poll.
type RunTimes = { scheduled: number; started: number; jobsRead?: number; plants: number };
async function logRun(spec: ShardSpec, ts: number, t: RunTimes, results: AccountResult[], error?: string): Promise<void> {
  if (spec.account) return;
  const failed = results.filter((r) => r.error).length;
  try {
    await rpc("poll_run_log", { p: {
      ts, shard: spec.shard, shards: spec.shards,
      scheduled_ms: t.scheduled, started_ms: t.started, jobs_read_ms: t.jobsRead ?? null,
      finished_ms: Date.now(), plants: t.plants,
      inverters: results.reduce((n, r) => n + r.inverters, 0),
      logins: results.map((r) => ({
        account: r.account, commit_ms: r.commitMs ?? null, plants: r.plants.length,
        inverters: r.inverters, error: r.error?.slice(0, 300) ?? null,
      })),
      error: error ?? (failed ? `${failed} of ${results.length} logins failed` : null),
    } });
  } catch (e) {
    console.warn("poll_run_log:", e instanceof Error ? e.message : e);
    noteError("run_log_failed", e, { hourly: true });
  }
}

// Work that may finish after the response; the runtime keeps the isolate for it.
const background = (p: Promise<unknown>) => (globalThis as any).EdgeRuntime?.waitUntil?.(p);

async function retryShareLogin() {
  try {
    const { data: id, error } = await db.rpc("share_retry_due");   // 0177
    if (error) throw new Error(error.message);
    if (!id) return;
    try {
      if (await shareAccount()) console.log("share login: signed in again");
    } catch (e) {
      // Logged as another stop, which the next try is timed from. Already stopped, so no email.
      const msg = e instanceof Error ? e.message : String(e);
      await db.rpc("account_mark", { p_account: id, p_status: "needs_relink", p_error: msg });
      console.warn("share login retry failed:", msg);
      noteError("share_login_retry_failed", e, { hourly: true });
    }
  } catch (e) {
    console.warn("share login retry skipped:", e instanceof Error ? e.message : e);
    noteError("share_login_retry_skipped", e, { hourly: true });
  } finally {
    await saveAllCalls();
    // Runs past the response, so serve() may have sent its notes already.
    await flushErrors();
  }
}

serve("poll", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  let spec: ShardSpec | undefined;
  let ts = 0;
  let times: RunTimes | undefined;
  let logged = false;
  try {
    spec = await shardSpec(req);
    // The minute this invocation is logging — fixed before the stagger delay so
    // a shard that waits 20 s still stamps the minute the cron tick was for.
    ts = nowMinuteEpoch();

    // Only this shard's plants; the shard hash (first 8 hex digits of the account
    // uuid, mod shards) runs in SQL.
    // SunSynk refused the share login: try the secret again an hour after the last try, so
    // shared plants restart without an owner pressing Check (SOLAR-451). Checked every
    // minute on one shard, so a missed minute only delays it a minute. Runs beside the
    // poll, not before it.
    if (spec.shard === 0 && !spec.account) background(retryShareLogin());

    // Wait first, then read the jobs, so tokens and plant versions are as they are when
    // the shard starts, not 20 s old (SOLAR-650).
    times = { scheduled: ts * 1000 + spec.delayMs, started: 0, plants: 0 };
    if (spec.delayMs > 0) await sleep(spec.delayMs);
    times.started = Date.now();

    let jobs = await pollJobs(spec.shard, spec.shards, spec.account);
    if (!jobs.length) {
      if (!spec.account && !(await plantsToPoll()).length) {
        // Nothing to poll anywhere: a fresh deploy. Link the env-credential account
        // so logging starts without anyone signing in. Only an empty shard pays for
        // the full read; on a running deployment the bootstrap never executes.
        try {
          if (await ensureBootstrapAccount()) jobs = await pollJobs(spec.shard, spec.shards);
        } catch (e) {
          console.warn("bootstrap skipped:", e instanceof Error ? e.message : e);
        }
      }
      if (!jobs.length) {
        times.jobsRead = Date.now();
        logged = true;
        await Promise.all([tallyCalls(spec, 0, 0, ts), logRun(spec, ts, times, []),
          spec.shard === 0 && !spec.account ? heartbeat("reader") : null]);
        return json({ ok: true, ts, ...spec, accounts: 0, note: "no accounts in this shard" });
      }
    }

    // Group jobs by account.
    const byAccount = new Map<string, { acc: Account; jobs: PlantJob[] }>();
    for (const j of jobs) {
      const entry = byAccount.get(j.account.id) ?? { acc: j.account, jobs: [] };
      entry.jobs.push(j);
      byAccount.set(j.account.id, entry);
    }
    const mine = [...byAccount.values()];
    times.jobsRead = Date.now();
    times.plants = jobs.length;
    const runStart = Date.now();

    // Accounts are independent; one dying must not stop the others.
    const results = await Promise.all(mine.map(({ acc, jobs }) =>
      pollAccount(acc, jobs, ts).catch((e) => accountFailed(acc, jobs, e))));

    // Email state (0102): how each login went, then step the plants just written.
    const outcomes = results.map(emailOutcome).filter((o) => o !== null);
    logged = true;
    const [stepped] = await Promise.all([
      rpc("email_poll_step", {
        p_ts: ts, p_outcomes: outcomes, p_plants: [...new Set(results.flatMap((r) => r.plants))],
      }).catch((e) => ({ error: e instanceof Error ? e.message : String(e) })),
      tallyCalls(spec, Date.now() - runStart, jobs.length, ts),
      logRun(spec, ts, times, results),
    ]);
    if ((stepped as any)?.error || (stepped as any)?.failed?.length) {
      console.warn("email_poll_step:", JSON.stringify(stepped));
      noteError("email_step_failed", new Error(`email_poll_step: ${(stepped as any).error ?? `${(stepped as any).failed.length} failed`}`), { hourly: true });
    }

    const ok = results.filter((r) => !r.error);
    // F12: the reader's heartbeat, once a minute from shard 0 when a login was read
    if (spec.shard === 0 && !spec.account && ok.length > 0) await heartbeat("reader");
    return json({
      ok: ok.length > 0,
      ts,
      ...spec,
      accounts: mine.length,
      succeeded: ok.length,
      inverters: ok.reduce((n, r) => n + r.inverters, 0),
      readings: ok.reduce((n, r) => n + r.readings, 0),
      strings: ok.reduce((n, r) => n + r.strings, 0),
      results,
    }, ok.length > 0 ? 200 : 502);
  } catch (e) {
    await reportError("poll", e);
    if (spec && times && !logged) await logRun(spec, ts, times, [], String(e instanceof Error ? e.message : e));
    console.error("poll failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
