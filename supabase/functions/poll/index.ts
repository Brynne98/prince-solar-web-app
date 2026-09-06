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
// Per account: fetch every inverter's realtime endpoints, map them with the shared
// extractReading(), and hand the whole minute (readings, per-string PV, metadata, a
// summed row per plant) to poll_commit(), which writes it in one transaction.
//
// Freshness gate (0032): `input` is fetched first. If its pvIV[0].time equals the
// device_time of the inverter's last stored row, the datalogger has not uploaded
// since, so the other four endpoints are skipped and the previous row's values are
// stored again under this minute, marked carried. See fetchInverter().
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
  num,
  type RawBundle,
  realtimePaths,
} from "../_shared/extract.ts";
import {
  type Account,
  apiCallCounts,
  apiGet,
  db,
  ensureBootstrapAccount,
  getInverters,
  getInvertersCached,
  type PlantJob,
  plantsToPoll,
  RelinkNeeded,
  syncPlants,
} from "../_shared/sunsynk.ts";

// The inverter and plant lists change rarely, so they are re-read from SunSynk only
// on minutes divisible by these and served from private.inverters/meta (0031)
// otherwise. The inverter list every 10 minutes (fleet composition, the online
// badge); the plant list hourly (a plant added at SunSynk after linking).
const REFRESH_EVERY_MIN = 10;
const PLANTS_EVERY_MIN = 60;

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
  /** inverters whose datalogger had not uploaded: input only, rest carried forward */
  carried?: string[];
  /** per inverter, the endpoints not read this minute (values copied / derived) */
  tiered?: Record<string, string[]>;
  /** inverter list re-read from SunSynk this minute (else served from cache) */
  listRefreshed: boolean;
  /** SunSynk requests spent on the inverter / plant lists this minute (0, 1 or 2+) */
  listCalls: number;
  /** SunSynk requests this account cost this minute, retries included */
  apiCalls: number;
  burst?: string;
  error?: string;
  needsRelink?: boolean;
};

const emptyResult = (acc: Account): AccountResult => ({
  account: acc.id, inverters: 0, readings: 0, strings: 0, plants: [], gapRecorded: [],
  listRefreshed: false, listCalls: 0, apiCalls: 0,
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

// ---------------------------------------------------------------------------
// Freshness gate + endpoint tiering.
//
// device_time (pvIV[0].time on /realtime/input) only advances when the datalogger
// uploads. The master does so about every 67 s, the slave every 5 minutes; a
// realtime call between uploads returns the previous sample again. So: fetch input
// first, compare its time with the last stored row, and only fetch the other
// endpoints when something new has arrived. Otherwise the previous row's
// battery/grid/load/output columns are stored again under this minute, with the
// fresh input fields, marked carried = true.
//
// Never carried: when the last row is unknown (first minute after linking) or has
// no device_time; when the last row
// showed an outage (relay open / mains < 100 V — the burst and the alerts need a
// live read); after MAX_CARRIED_RUN carried rows in a row, so a stalled logger is
// re-read; when input itself failed.
//
// When something new has arrived, not every endpoint is worth a call (0033):
// battery and grid every time (SoC, battery power, mains voltage and the relay are
// the alert inputs); `load` only when its last real read is LOAD_EVERY_S old, and
// load_w is derived from the energy balance in between; `output` only when its last
// real read is OUTPUT_EVERY_S old. Both every minute while the grid is down. The
// age lives in the row itself (load_fetched_ts / output_fetched_ts) so a slow logger
// whose real minute never lands on a multiple of five still gets its load read.
// ---------------------------------------------------------------------------
const MAX_CARRIED_RUN = 5;
const LOAD_EVERY_S = 300;
const OUTPUT_EVERY_S = 600;

type Endpoint = "battery" | "grid" | "load" | "output";
const ALL_ENDPOINTS: Endpoint[] = ["battery", "grid", "load", "output"];

/** Columns that come from `input` and are therefore fresh on a carried row too. */
const INPUT_FIELDS = ["device_time", "pv_w", "pv_today_kwh", "pv_total_kwh"] as const;

/** Which readings columns each of the other four endpoints produces (extractReading). */
const ENDPOINT_FIELDS: Record<Endpoint, string[]> = {
  battery: [
    "batt_power_w", "batt_w", "batt_soc", "batt_voltage_v", "batt_current_a", "batt_temp_c",
    "batt_chg_today_kwh", "batt_dischg_today_kwh", "batt_chg_total_kwh", "batt_dischg_total_kwh",
  ],
  grid: [
    "grid_w", "grid_import_today_kwh", "grid_export_today_kwh", "grid_import_total_kwh",
    "grid_export_total_kwh", "grid_freq_hz", "grid_pf", "grid_volt_v", "grid_relay_status",
  ],
  load: ["load_w", "load_today_kwh", "load_total_kwh", "load_freq_hz"],
  output: ["output_w", "output_volt_v", "output_freq_hz"],
};

type Fetched = { inv: InverterInfo; raw: RawBundle; carried: boolean; fetched: Set<Endpoint> };

function canCarry(inv: InverterInfo, inputTime: string | null): boolean {
  const prev = inv.lastReading;
  if (!prev || inputTime == null || prev.device_time == null) return false;
  if (prev.device_time !== inputTime) return false;
  if ((inv.carriedRun ?? 0) >= MAX_CARRIED_RUN) return false;
  if (burstTrigger(prev) !== null) return false;
  return true;
}

/** Which of the four non-input endpoints this minute needs, given the last row. */
function wantEndpoints(prev: Record<string, unknown> | null | undefined, ts: number): Set<Endpoint> {
  if (!prev) return new Set(ALL_ENDPOINTS);
  const want = new Set<Endpoint>(["battery", "grid"]);
  const age = (k: string) => ts - (Number(prev[k]) || 0); // null/absent -> very old
  if (prev.load_w == null || age("load_fetched_ts") >= LOAD_EVERY_S) want.add("load");
  if (age("output_fetched_ts") >= OUTPUT_EVERY_S) want.add("output");
  if (burstTrigger(prev) !== null) { want.add("load"); want.add("output"); }
  return want;
}

async function fetchInto(raw: RawBundle, eps: Endpoint[], sn: string, acc: Account): Promise<void> {
  const paths = realtimePaths(sn);
  const settled = await Promise.allSettled(eps.map((k) => apiGet(paths[k], acc)));
  eps.forEach((k, i) => {
    raw[k] = settled[i].status === "fulfilled" ? (settled[i] as PromiseFulfilledResult<any>).value : null;
  });
}

async function fetchInverter(inv: InverterInfo, acc: Account, ts: number): Promise<Fetched> {
  const paths = realtimePaths(inv.sn);
  const input = await apiGet(paths.input, acc).catch(() => null);
  const inputTime: string | null =
    (input && Array.isArray(input.pvIV) && input.pvIV[0] && input.pvIV[0].time) || null;
  const raw: RawBundle = { input, grid: null, battery: null, load: null, output: null };
  if (canCarry(inv, inputTime)) return { inv, raw, carried: true, fetched: new Set() };

  const want = wantEndpoints(inv.lastReading, ts);
  await fetchInto(raw, [...want], inv.sn, acc);

  // The fresh grid payload shows an outage that the last row did not: read the far
  // side of the relay (and the load) now rather than at the next tier boundary.
  const late = (["output", "load"] as Endpoint[]).filter((k) => !want.has(k));
  if (late.length && burstTrigger(extractReading(inv, raw)) !== null) {
    await fetchInto(raw, late, inv.sn, acc);
    for (const k of late) want.add(k);
  }
  return { inv, raw, carried: false, fetched: want };
}

/**
 * The readings row for this minute. Carried: the last row with fresh input fields.
 * Otherwise: fresh values for the endpoints fetched, the last row's for the rest,
 * load_w derived from the balance when load was not read.
 */
function readingRow(f: Fetched, ts: number): Record<string, unknown> {
  const fresh = extractReading(f.inv, f.raw);
  const plant_id = f.inv.plantId ?? null;
  const prev = f.inv.lastReading ?? {};
  if (f.carried) {
    const row: Record<string, unknown> = { ...prev, ts, plant_id, sn: f.inv.sn, status: fresh.status };
    for (const k of INPUT_FIELDS) row[k] = fresh[k];
    row.carried = true;
    return row;
  }
  const row: Record<string, unknown> = { ts, plant_id, sn: f.inv.sn, status: fresh.status, carried: false };
  for (const k of INPUT_FIELDS) row[k] = fresh[k];
  for (const ep of ALL_ENDPOINTS) {
    const src = f.fetched.has(ep) ? fresh : prev;
    for (const col of ENDPOINT_FIELDS[ep]) row[col] = src[col] ?? null;
  }
  row.load_fetched_ts = f.fetched.has("load") ? ts : (prev.load_fetched_ts ?? null);
  row.output_fetched_ts = f.fetched.has("output") ? ts : (prev.output_fetched_ts ?? null);
  if (!f.fetched.has("load")) {
    // grid + = import, batt + = charging (DATA_PIPELINE §9A); counters stay carried
    row.load_w = Math.max(0, Math.round(num(row.pv_w) + num(row.grid_w) - num(row.batt_w)));
  }
  return row;
}

async function pollAccount(acc: Account, jobs: PlantJob[], ts: number): Promise<AccountResult> {
  const result = emptyResult(acc);
  const callsAtStart = apiCallCounts.get(acc.id) ?? 0;
  const wanted = new Set(jobs.map((j) => j.plantId));

  // Inverter list: from the cache, unless it is this account's refresh minute or
  // the cache is empty (first minute after linking). On a refresh minute the live
  // list is merged with the cache so each inverter keeps its last row and carry
  // run: the freshness gate and tiering then apply on refresh minutes too.
  // The plant list is re-read hourly so a plant added at SunSynk starts logging.
  const refreshMinute = (ts / 60) % REFRESH_EVERY_MIN === 0;
  const plantsMinute = (ts / 60) % PLANTS_EVERY_MIN === 0;
  const cached = await getInvertersCached(acc);
  let all = cached;
  if (refreshMinute || !cached.length) {
    result.listRefreshed = true;
    const bySn = new Map(cached.map((c) => [c.sn, c]));
    all = (await getInverters(acc)).map((inv) => {
      const c = bySn.get(inv.sn);
      return c ? { ...inv, lastReading: c.lastReading, carriedRun: c.carriedRun } : inv;
    });
  }
  if (plantsMinute || !cached.length) {
    try {
      const plants = await syncPlants(acc);
      for (const p of plants) wanted.add(p.id);
    } catch (e) {
      console.warn(`plant refresh failed for ${acc.id}:`, e instanceof Error ? e.message : e);
    }
  }
  result.listCalls = callsSince(acc, callsAtStart);
  const inverters = all.filter((inv) => inv.plantId != null && wanted.has(Number(inv.plantId)));
  const skipped = all.filter((inv) => !inverters.includes(inv)).map((inv) => inv.sn);
  if (skipped.length) result.skipped = skipped;
  result.apiCalls = callsSince(acc, callsAtStart);
  if (!inverters.length) return result;
  result.inverters = inverters.length;

  const perInv = await Promise.all(inverters.map((inv) => fetchInverter(inv, acc, ts)));
  const carried = perInv.filter((f) => f.carried).map((f) => f.inv.sn);
  if (carried.length) result.carried = carried;
  const tiered = Object.fromEntries(perInv
    .filter((f) => !f.carried && f.fetched.size < ALL_ENDPOINTS.length)
    .map((f) => [f.inv.sn, ALL_ENDPOINTS.filter((k) => !f.fetched.has(k))]));
  if (Object.keys(tiered).length) result.tiered = tiered;

  const readings = perInv.map((f) => readingRow(f, ts));
  // Strings come from input, which is always fetched, so they are fresh every minute.
  const strings = perInv.flatMap(({ inv, raw }) =>
    extractStrings(inv, raw).map((s) => ({ ts, plant_id: inv.plantId ?? null, ...s }))
  );
  // Meta reads battery capacity off the battery payload; a carried inverter has no
  // battery payload this minute, so leave its meta row alone rather than zero it.
  // (A tiered inverter always has one: battery is never tiered.)
  const meta = perInv
    .map(({ inv, raw, carried }, i) => (carried ? null : extractMeta(inv, raw, ts, i)))
    .filter((m) => m !== null);

  // One aggregate row per plant on this account.
  const plantIds = [...new Set(readings.map((r) => r.plant_id as number))];
  const agg = plantIds.map((plantId) => ({
    plant_id: plantId,
    ...aggregate(readings.filter((r) => r.plant_id === plantId) as any),
  }));

  // The whole minute in one transaction (migration 0030): readings and strings
  // last-write-wins, agg_minute first-write-wins with gap detection, meta, the
  // inverter mirror and the account's token. fetchInverter may have refreshed
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
