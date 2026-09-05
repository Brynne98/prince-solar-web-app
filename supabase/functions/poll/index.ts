// `poll` — the per-minute logger, sharded across linked accounts.
//
// pg_cron fires this every minute — once per SHARD (migration 0030). The request
// body carries {shard, shards, delay_ms}; this invocation keeps the accounts whose
// id hashes into its shard, waits delay_ms so the fleet is spread over the minute
// instead of hitting SunSynk at second zero, then polls its accounts in parallel.
// No body (local dev, manual invoke) means "every account, no delay".
//
// The set of plants to log comes from plantsToPoll() — plant_users is the source of
// truth for what a user can see, so it is also what gets stored. Jobs are grouped by
// account so each account's inverter list is fetched once.
//
// Per account: fetch every inverter's 5 realtime endpoints, map them with the shared
// extractReading(), and hand the whole minute (readings, per-string PV, metadata, a
// summed row per plant) to poll_commit(), which writes it in one transaction.
//
// An account whose refresh token has died (password changed, token revoked) is
// marked needs_relink and skipped; the others continue. Any other per-account
// failure is recorded on the row and the account stays active for the next tick.
//
// Deliberately NOT ported: the gzipped `raw` payload table. It was 46 MB of the
// 96 MB SQLite file, has no dashboard consumer, and may embed account identifiers.
import {
  aggregate,
  extractMeta,
  extractReading,
  extractStrings,
  type InverterInfo,
  realtimePaths,
} from "../_shared/extract.ts";
import {
  type Account,
  apiCallCounts,
  apiGet,
  db,
  ensureBootstrapAccount,
  fetchInverterRaw,
  getInverters,
  getInvertersCached,
  type PlantJob,
  plantsToPoll,
  RelinkNeeded,
  syncPlants,
} from "../_shared/sunsynk.ts";

// The inverter and plant lists change rarely, so they are re-read from SunSynk only
// on minutes divisible by this and served from private.inverters/meta (0031)
// otherwise. One list call per account per REFRESH_EVERY_MIN instead of per minute.
const REFRESH_EVERY_MIN = 10;

/** epoch seconds for the current minute — the dedup key for a sample */
const nowMinuteEpoch = () => Math.floor(Date.now() / 60000) * 60;

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

type AccountResult = {
  account: string;
  inverters: number;
  readings: number;
  strings: number;
  plants: number[];
  gapRecorded: number[];
  /** inverters on a plant nobody has linked; fetched nothing, stored nothing */
  skipped?: string[];
  /** inverter + plant lists re-read from SunSynk this minute (else served from cache) */
  listRefreshed: boolean;
  /** SunSynk requests this account cost this minute, retries included */
  apiCalls: number;
  burst?: string;
  error?: string;
  needsRelink?: boolean;
};

const emptyResult = (acc: Account): AccountResult => ({
  account: acc.id, inverters: 0, readings: 0, strings: 0, plants: [], gapRecorded: [],
  listRefreshed: false, apiCalls: 0,
});

/** SunSynk requests made for this account since `since`. */
const callsSince = (acc: Account, since: number) => (apiCallCounts.get(acc.id) ?? 0) - since;

// ---------------------------------------------------------------------------
// Grid burst: sub-minute samples after a relay-open / low-voltage minute.
//
// The one relay-open minute on record (2026-09-04 11:15) was sampled AFTER the
// utility had returned -- grid_volt_v and output_volt_v, identical with the relay
// closed, differed by 12.9 V, so the grid-side sensor was seeing live mains while the
// inverter sat in its reconnect delay. The dead-grid interval fell between polls.
// Nothing logged so far shows what this firmware reports while the grid is actually
// OFF, which is the fact 0017's alert wording is waiting on.
//
// So when a poll sees the trigger, take BURST_SAMPLES more readings at
// BURST_SPACING_MS, grid + output endpoints only, and store them in grid_burst
// (migration 0029). Bounded to finish before the next minute's poll, which re-arms
// if the relay is still open -- so an event of any length gets ~10 s coverage with
// no overlap and no unbounded work.
//
// Runs after the response via EdgeRuntime.waitUntil, so the burst never delays the
// minute's normal write and the cron job's 55 s wait is unaffected.
// ---------------------------------------------------------------------------
const BURST_SAMPLES = 5;
const BURST_SPACING_MS = 10_000;
const BURST_BUDGET_MS = 55_000; // hard stop: the next poll starts at +60 s
const LOW_VOLT_V = 100;         // same threshold as q_grid_present()

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Why a reading triggers a burst, or null if it doesn't. */
function burstTrigger(r: Record<string, unknown>): "relay_open" | "low_volt" | null {
  if (r.grid_relay_status === "0") return "relay_open";
  const v = r.grid_volt_v;
  if (typeof v === "number" && v < LOW_VOLT_V) return "low_volt";
  return null;
}

async function burstGrid(
  acc: Account, inverters: InverterInfo[], triggerTs: number, trigger: string,
): Promise<void> {
  const started = Date.now();
  let stored = 0;
  for (let i = 0; i < BURST_SAMPLES; i++) {
    if (i > 0) await sleep(BURST_SPACING_MS);
    if (Date.now() - started > BURST_BUDGET_MS) break;
    const ts = Math.floor(Date.now() / 1000);

    // Grid + output only: the two sensors that straddle the relay. Every inverter on
    // the account, not just the one that tripped -- the slave's stale feed is part
    // of what needs observing.
    const rows = await Promise.all(inverters.map(async (inv) => {
      const paths = realtimePaths(inv.sn);
      const [grid, output] = await Promise.all([
        apiGet(paths.grid, acc).catch(() => null),
        apiGet(paths.output, acc).catch(() => null),
      ]);
      const r = extractReading(inv, { grid, output, battery: null, input: null, load: null });
      return {
        ts, sn: inv.sn, plant_id: inv.plantId ?? null, trigger, trigger_ts: triggerTs,
        grid_volt_v: r.grid_volt_v, grid_relay_status: r.grid_relay_status,
        grid_freq_hz: r.grid_freq_hz, grid_w: r.grid_w,
        output_volt_v: r.output_volt_v, output_freq_hz: r.output_freq_hz,
      };
    }));
    const withPlant = rows.filter((r) => r.plant_id != null);
    if (!withPlant.length) continue;
    const ins = await db.from("grid_burst").upsert(withPlant, { onConflict: "ts,sn" });
    if (ins.error) { console.warn("grid_burst:", ins.error.message); continue; }
    stored += withPlant.length;
  }
  console.log(`grid burst (${trigger} @ ${triggerTs}): ${stored} rows in ${Date.now() - started} ms`);
}

/** Run after the response if the runtime supports it; otherwise inline (local dev). */
function background(p: Promise<void>) {
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(p);
  else return p;
}

async function pollAccount(acc: Account, jobs: PlantJob[], ts: number): Promise<AccountResult> {
  const result = emptyResult(acc);
  const callsAtStart = apiCallCounts.get(acc.id) ?? 0;
  const wanted = new Set(jobs.map((j) => j.plantId));

  // Inverter list: from the cache, unless it is this account's refresh minute or
  // the cache is empty (first minute after linking). The refresh minute also
  // re-reads the plant list so a plant added at SunSynk later starts logging.
  const refreshMinute = (ts / 60) % REFRESH_EVERY_MIN === 0;
  let all = refreshMinute ? [] : await getInvertersCached(acc);
  if (!all.length) {
    result.listRefreshed = true;
    all = await getInverters(acc);
    if (refreshMinute) {
      try {
        const plants = await syncPlants(acc);
        for (const p of plants) wanted.add(p.id);
      } catch (e) {
        console.warn(`plant refresh failed for ${acc.id}:`, e instanceof Error ? e.message : e);
      }
    }
  }
  const inverters = all.filter((inv) => inv.plantId != null && wanted.has(Number(inv.plantId)));
  const skipped = all.filter((inv) => !inverters.includes(inv)).map((inv) => inv.sn);
  if (skipped.length) result.skipped = skipped;
  result.apiCalls = callsSince(acc, callsAtStart);
  if (!inverters.length) return result;
  result.inverters = inverters.length;

  const perInv = await Promise.all(
    inverters.map(async (inv) => ({ inv, raw: await fetchInverterRaw(inv.sn, acc) })),
  );

  const readings = perInv.map(({ inv, raw }) => ({
    ts, plant_id: inv.plantId ?? null, ...extractReading(inv, raw),
  }));
  const strings = perInv.flatMap(({ inv, raw }) =>
    extractStrings(inv, raw).map((s) => ({ ts, plant_id: inv.plantId ?? null, ...s }))
  );
  const meta = perInv.map(({ inv, raw }, i) => extractMeta(inv, raw, ts, i));

  // One aggregate row per plant on this account.
  const plantIds = [...new Set(readings.map((r) => r.plant_id as number))];
  const agg = plantIds.map((plantId) => ({
    plant_id: plantId,
    ...aggregate(readings.filter((r) => r.plant_id === plantId) as any),
  }));

  // The whole minute in one transaction (migration 0030): readings and strings
  // last-write-wins, agg_minute first-write-wins with gap detection, meta, the
  // inverter mirror and the account's token. fetchInverterRaw may have refreshed
  // the token, so read it off `acc` here rather than from the row we started with.
  const committed = await rpc("poll_commit", {
    p_account: acc.id,
    p_ts: ts,
    p_readings: readings,
    p_strings: strings,
    p_agg: agg,
    p_meta: meta,
    p_inverters: inverters.map((i) => ({ sn: i.sn, plant_id: i.plantId ?? null, account_id: acc.id })),
    p_access: acc.access_token,
    p_expires: acc.access_expires_at,
  }) as { readings: number; strings: number; plants: number[]; gaps: number[] };
  result.readings = committed.readings;
  result.strings = committed.strings;
  result.plants = committed.plants;
  result.gapRecorded = committed.gaps;

  // Relay open or mains voltage gone on any inverter: start the sub-minute burst.
  const trigger = readings.map(burstTrigger).find((t) => t !== null) ?? null;
  if (trigger) {
    result.burst = trigger;
    const p = burstGrid(acc, inverters, ts, trigger)
      .catch((e) => console.warn("grid burst failed:", e instanceof Error ? e.message : e));
    await background(p);
  }

  result.apiCalls = callsSince(acc, callsAtStart);
  return result;
}

// ---------------------------------------------------------------------------
// Sharding. The cron job (0030) decides how many invocations this minute needs
// and POSTs {shard, shards, delay_ms} to each. An account belongs to exactly one
// shard, chosen by a stable hash of its uuid, so no two isolates ever work the
// same account (or refresh the same token) in the same minute.
// ---------------------------------------------------------------------------
type ShardSpec = { shard: number; shards: number; delayMs: number };

const MAX_DELAY_MS = 30_000; // never eat more of the minute than the cron job planned for

async function shardSpec(req: Request): Promise<ShardSpec> {
  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const shards = Math.max(1, Math.floor(Number(body.shards) || 1));
  const shard = Math.min(shards - 1, Math.max(0, Math.floor(Number(body.shard) || 0)));
  const delayMs = Math.min(MAX_DELAY_MS, Math.max(0, Math.floor(Number(body.delay_ms) || 0)));
  return { shard, shards, delayMs };
}

/** Stable shard for an account: first 8 hex digits of its uuid, mod shard count. */
function shardOf(accountId: string, shards: number): number {
  const hex = accountId.replace(/-/g, "").slice(0, 8);
  return (parseInt(hex, 16) >>> 0) % shards;
}

Deno.serve(async (req) => {
  try {
    const spec = await shardSpec(req);
    // The minute this invocation is logging — fixed before the stagger delay so
    // a shard that waits 20 s still stamps the minute the cron tick was for.
    const ts = nowMinuteEpoch();

    let jobs = await plantsToPoll();
    if (!jobs.length) {
      // Nothing to poll: a fresh deploy. Link the env-credential account so
      // logging starts without anyone signing in. Only the empty case pays for
      // this; on a running deployment it never executes.
      try {
        if (await ensureBootstrapAccount()) jobs = await plantsToPoll();
      } catch (e) {
        console.warn("bootstrap skipped:", e instanceof Error ? e.message : e);
      }
      if (!jobs.length) return json({ ok: true, ts, ...spec, accounts: 0, note: "no plants to poll" });
    }

    // Group jobs by account, keep this shard's accounts.
    const byAccount = new Map<string, { acc: Account; jobs: PlantJob[] }>();
    for (const j of jobs) {
      const entry = byAccount.get(j.account.id) ?? { acc: j.account, jobs: [] };
      entry.jobs.push(j);
      byAccount.set(j.account.id, entry);
    }
    const mine = [...byAccount.values()].filter(({ acc }) => shardOf(acc.id, spec.shards) === spec.shard);
    if (!mine.length) return json({ ok: true, ts, ...spec, accounts: 0, note: "no accounts in this shard" });

    if (spec.delayMs > 0) await sleep(spec.delayMs);

    // Accounts are independent; one dying must not stop the others.
    const results = await Promise.all(mine.map(async ({ acc, jobs }): Promise<AccountResult> => {
      try {
        return await pollAccount(acc, jobs, ts);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        const needsRelink = e instanceof RelinkNeeded;
        await rpc("account_mark", {
          p_account: acc.id, p_status: needsRelink ? "needs_relink" : "active", p_error: msg,
        }).catch(() => {});
        console.error(`poll: account ${acc.id} failed:`, msg);
        return { ...emptyResult(acc), error: msg, ...(needsRelink ? { needsRelink } : {}) };
      }
    }));

    const ok = results.filter((r) => !r.error);
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
    console.error("poll failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
