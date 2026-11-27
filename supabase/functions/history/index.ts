// `history` — every past day from the brand, through one queue (SOLAR-686,
// reports/rework-step-3-history.md). Replaces `recover` and `sync-plant-energy`.
//
//   { task: "queue", shard, shards }  every minute, one call per group of 25 logins (H9): takes
//       one step per login from history.take, runs them side by side, reports each to
//       history.step_done, and takes again until 45 s are used. A step is a day's minutes, a
//       day's extras, or a plant's kWh totals; each holds its claim (renewed every 30 s) and
//       every write carries it (H6).
//   { task: "check" }   6-hourly: queues the last 14 days' holes and yesterday's temperatures.
//   { task: "trim" }    daily: rolls inverter history past 31 days into 5-minute rows (H13).
//   { task: "temps" }   every minute: today's temperatures and grid Hz (H12).
//   ?dry=1&plant=ID&day=YYYY-MM-DD  a day's spine against its reader rows, writing nothing (H22).
//
// The server key only.
import { denyUnlessServer } from "../_shared/server.ts";
import { brandOf, saveAllCalls } from "../_shared/brands/index.ts";
import { plantsToPoll } from "../_shared/plants.ts";
import { noteError, reportError, serve } from "../_shared/errors.ts";
import { rpc } from "../_shared/db.ts";
import { dryRun, runExtras, runMinutes } from "./day.ts";
import { runTotals } from "./totals.ts";
import { runTemps } from "./temps.ts";
import { isRefused, jobs, type Result, type Step } from "./step.ts";

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
// every minute from pg_cron: stop well inside the minute so runs do not pile up
const QUEUE_BUDGET_MS = 45_000;
const RENEW_MS = 30_000;
const IDLE_WAIT_MS = 5_000;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** One step, start to end. Throws nothing: an error is a failed step. */
export async function runStep(s: Step & { refused?: boolean }): Promise<Result> {
  const h = brandOf(s.login.brand).history;
  const before = h.throttled(s.login);
  let lost = false;
  const renew = setInterval(() => {
    jobs("renew", { step: s.step, id: s.id, claim: s.claim }).then((ok) => { if (ok !== true) { lost = true; s.refused = true; } })
      .catch(() => {});
  }, RENEW_MS);
  let r: Result;
  try {
    r = s.kind === "minutes" ? await runMinutes(s) : s.kind === "extras" ? await runExtras(s) : await runTotals(s);
  } catch (e) {
    if (isRefused(e)) r = { result: "refused" };
    else {
      noteError("history_step_failed", e, { plant: s.plant, hourly: true });
      r = { result: "failed", note: String(e instanceof Error ? e.message : e).slice(0, 300) };
    }
  } finally {
    clearInterval(renew);
  }
  if (lost) return { result: "refused", note: "claim lost" };
  // a 429 that outlasted the adapter's retries: the login backs off, no try spent (H7)
  if (r.result === "failed" && h.throttled(s.login) > before) r = { result: "throttled", note: r.note };
  const end = await jobs<{ status?: string }>("done", { step: s.step, id: s.id, claim: s.claim, result: r.result, note: r.note ?? null });
  if (end?.status === "given_up") {
    noteError("history_day_given_up", new Error(`history ${s.plant} ${s.day ?? "totals"} ${s.kind} given up: ${r.note ?? ""}`), { plant: s.plant, hourly: true });
  }
  return r;
}

async function runQueue(shard: number, shards: number, started: number) {
  const out = { steps: 0, calls: 0, results: {} as Record<string, number> };
  for (;;) {
    if (Date.now() - started > QUEUE_BUDGET_MS) break;
    const steps = ((await jobs<Step[]>("take", { shard, shards })) ?? []).filter(Boolean);
    if (!steps.length) {
      // a paced import's next row may be seconds away; look once more, then leave it to the next minute
      if (Date.now() - started + IDLE_WAIT_MS > QUEUE_BUDGET_MS) break;
      await sleep(IDLE_WAIT_MS);
      const again = ((await jobs<Step[]>("take", { shard, shards })) ?? []).filter(Boolean);
      if (!again.length) break;
      steps.push(...again);
    }
    const done = await Promise.all(steps.map((s) => runStep(s)));
    out.steps += steps.length;
    out.calls += steps.reduce((n, s) => n + s.calls, 0);
    for (const r of done) out.results[r.result] = (out.results[r.result] ?? 0) + 1;
  }
  return out;
}

async function runTrim() {
  const plants = (await jobs<number[]>("trim_plants")) ?? [];
  let pruned = 0, failed = 0;
  for (const p of plants) {
    try { pruned += Number(await rpc("q_prune_inverter_history", { p_plant: p }) ?? 0); }
    catch (e) { failed++; noteError("prune_failed", e, { plant: p, hourly: true }); }
  }
  return { plants: plants.length, pruned, failed };
}

const nowMinuteEpoch = () => Math.floor(Date.now() / 60000) * 60;

if (import.meta.main) serve("history", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  const started = Date.now();
  try {
    const url = new URL(req.url);
    if (url.searchParams.get("dry") === "1") {
      const plant = Number(url.searchParams.get("plant"));
      const day = url.searchParams.get("day") ?? "";
      const job = (await plantsToPoll()).find((j) => j.plantId === plant);
      if (!job || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return json({ error: "dry run needs plant=<read plant id>&day=YYYY-MM-DD" }, 400);
      const web = url.searchParams.get("source") !== "official";
      return json({ ok: true, dry: true, plant, day, ...(await dryRun({ plant, day, timezone: job.timezone, login: job.account }, web)) });
    }
    const body = await req.json().catch(() => ({})) as Record<string, unknown>;
    switch (body.task) {
      case "queue": return json({ ok: true, task: "queue", ...(await runQueue(Number(body.shard) || 0, Number(body.shards) || 1, started)) });
      case "check": return json({ ok: true, task: "check", ...(await jobs("check")) });
      case "trim": return json({ ok: true, task: "trim", ...(await runTrim()) });
      case "temps": return json({ ok: true, task: "temps", ...(await runTemps(nowMinuteEpoch())) });
      default: return json({ error: "task must be queue, check, trim or temps" }, 400);
    }
  } catch (e) {
    await reportError("history", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  } finally {
    await saveAllCalls();
  }
});
