// The per-inverter reading of one login for one minute (SOLAR-656: moved out of poll/index.ts
// so another host can run it). pollAccount reads every inverter of the login's plants and
// saves the minute through the database handle in db.ts (poll_commit_v2). The edge `poll`
// function calls it per login; what it does is described there.
import { noteError } from "./errors.ts";
import { clearYesterday, dayTurned, fromPrev, TODAY_COUNTERS } from "../poll/newday.mts";
import { dayStartEpoch, extrasOf, extrasPaths, historyRows, localDate, parseSeries } from "./invhistory.ts";
import {
  aggregate,
  DEFAULT_BATT_POSITIVE_MEANS,
  extractMeta,
  extractReading,
  extractStrings,
  type InverterInfo,
  num,
  type RawBundle,
  realtimePaths,
} from "./extract.ts";
import { rpc } from "./db.ts";
import {
  type Account,
  apiCallCounts,
  apiGet,
  getInverters,
  getInvertersCached,
  isShareAccount,
  type PlantJob,
  RelinkNeeded,
  shareSync,
  SignInFailed,
  syncPlants,
} from "./sunsynk.ts";
import { holdLastGood } from "../poll/hold.mts";
// The inverter and plant lists change rarely, so they are re-read from SunSynk only on
// the login's own minutes (SOLAR-650) and served from private.inverters/meta (0031)
// otherwise. The inverter list every 10 minutes (fleet composition, the online badge);
// the plant list hourly (a plant added at SunSynk after linking).
import { isListMinute, isPlantsMinute } from "../poll/minutes.mts";

export type AccountResult = {
  account: string;
  inverters: number;
  readings: number;
  strings: number;
  plants: number[];
  gapRecorded: number[];
  /** plants switched or deleted while this minute was read: nothing written (0246) */
  refused?: number[];
  /** inverters on a plant nobody has linked; fetched nothing, stored nothing */
  skipped?: string[];
  /** inverters whose datalogger had not uploaded: input only, rest carried forward */
  carried?: string[];
  /** per inverter, the endpoints not read this minute (values copied / derived) */
  tiered?: Record<string, string[]>;
  /** inverters that answered with nothing at all this minute; no row stored */
  noData?: string[];
  /** inverters whose today's temperatures were fetched this minute: rows banked, or the error (SOLAR-398) */
  temps?: Record<string, number | string>;
  /** inverter list re-read from SunSynk this minute (else served from cache) */
  listRefreshed: boolean;
  /** SunSynk requests spent on the inverter / plant lists this minute (0, 1 or 2+) */
  listCalls: number;
  /** SunSynk requests this account cost this minute, retries included */
  apiCalls: number;
  /** ms after the minute that poll_commit_v2 answered: when the readings became visible */
  commitMs?: number;
  error?: string;
  needsRelink?: boolean;
  signInFailed?: boolean;
};

export const emptyResult = (acc: Account): AccountResult => ({
  account: acc.id, inverters: 0, readings: 0, strings: 0, plants: [], gapRecorded: [],
  listRefreshed: false, listCalls: 0, apiCalls: 0,
});

/**
 * A login whose read or save threw: marked on its row (needs_relink when its refresh token is
 * dead), logged, and noted for PostHog unless the owner must fix it. Returns its result.
 */
export async function accountFailed(acc: Account, jobs: { plantId: number }[], e: unknown): Promise<AccountResult> {
  const msg = e instanceof Error ? e.message : String(e);
  const needsRelink = e instanceof RelinkNeeded;
  await rpc("account_mark", {
    p_account: acc.id, p_status: needsRelink ? "needs_relink" : "active", p_error: msg,
  }).catch(() => {});
  console.error(`poll: account ${acc.id} failed:`, msg);
  // A dead login is the owner's to fix and is mailed to them; the rest are ours or SunSynk's.
  if (!needsRelink) {
    const kind = e instanceof SignInFailed ? "sign_in" : /^[a-z_]+: /.test(msg) ? "ours" : "sunsynk";
    for (const j of jobs) noteError(`account_failed_${kind}`, e, { user: acc.user_id, plant: j.plantId, hourly: true });
  }
  return { ...emptyResult(acc), error: msg, ...(needsRelink ? { needsRelink } : {}),
    ...(e instanceof SignInFailed ? { signInFailed: true } : {}) };
}

/**
 * How a login's minute went, for email_poll_step (0102), or null to leave it out. SunSynk's
 * fault and ours are told apart so our own outage is never mailed as SunSynk's: our errors
 * are rpc failures ("fn: message"); a dead login is left out, and so is one we could not
 * sign in (SOLAR-451): no read was made, so it says nothing about the inverter.
 */
export function emailOutcome(r: AccountResult): { account: string; outcome: string } | null {
  if (r.needsRelink || r.signInFailed) return null;
  return {
    account: r.account,
    outcome: r.error ? (/^[a-z_]+: /.test(r.error) ? "ours" : "sunsynk")
           : r.inverters > 0 && r.readings === 0 ? "sunsynk" : "ok",
  };
}

/** SunSynk requests made for this account since `since`. */
const callsSince = (acc: Account, since: number) => (apiCallCounts.get(acc.id) ?? 0) - since;

// ---------------------------------------------------------------------------
// Outage signal: does this reading look like the grid is gone?
//
// Three unrelated things need to know. `canCarry` refuses to carry such a row
// forward, because freezing an outage minute is worse than fetching again.
// `wantEndpoints` forces the load and output reads, which are otherwise on 5 and
// 10 minute tiers. And `fetchInverter` reads the far side of the relay early
// rather than waiting for the next tier boundary.
//
// The threshold is q_grid_present's: mains voltage collapses to a few volts of
// sensor float when the supply fails -- 15.2 V decaying to 6.5 V on the master
// through the 18 Sep outage, 5.0 V on the slave, exactly 0.0 V on another plant
// entirely. Relay '0' alone is not specific: the inverter also opens it on
// purpose when it is running the house off the battery.
// ---------------------------------------------------------------------------
export const LOW_VOLT_V = 100;         // same threshold as q_grid_present()


/** Why a reading looks like an outage, or null if it doesn't. */
export function outageSignal(r: Record<string, unknown>): "relay_open" | "low_volt" | null {
  if (r.grid_relay_status === "0") return "relay_open";
  const v = r.grid_volt_v;
  if (typeof v === "number" && v < LOW_VOLT_V) return "low_volt";
  return null;
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
// showed an outage (relay open / mains < 100 V — the alerts need a live read); after MAX_CARRIED_RUN carried rows in a row, so a stalled logger is
// re-read; when input itself failed.
//
// When something new has arrived, not every endpoint is worth a call (0033):
// battery, grid and load every time. Load used to be read every 5 minutes and derived
// from pv + grid - batt in between, but that sum leaves out the inverter's own use, so
// Home read 20-175 W high on four minutes in five (SOLAR-40). `output` only when its
// last real read is OUTPUT_EVERY_S old, and every minute while the grid is down. The
// age lives in the row itself (output_fetched_ts) so a slow logger whose real minute
// never lands on a multiple of ten still gets its output read.
// ---------------------------------------------------------------------------
export const MAX_CARRIED_RUN = 5;
export const OUTPUT_EVERY_S = 600;

// ---------------------------------------------------------------------------
// Today's inverter temperatures (SOLAR-398). SunSynk sends no live temperature on
// our key, only its day history (output/day). Recover fetches it for past days only;
// here each inverter fetches today's once in ten minutes, on its own minute (spread
// by serial), so Equipment's temperature is ten minutes old at most plus the
// logger's upload (master ~67 s, slave 5 min). One call: AC/DC temperature, AC
// terminal volts and output Hz. The insert keeps what a row already holds (0046).
// ---------------------------------------------------------------------------
export const TEMP_EVERY_MIN = 10;
export const tempMinute = (sn: string) => [...sn].reduce((h, c) => h + c.charCodeAt(0), 0) % TEMP_EVERY_MIN;

export async function bankTodayTemps(inv: InverterInfo, acc: Account, tz: string, version: number | null): Promise<number> {
  const day = localDate(tz);
  const out = await apiGet(extrasPaths(inv.sn, day).output, acc);
  const rows = historyRows(extrasOf(parseSeries(out), undefined), dayStartEpoch(tz, day));
  if (!rows.length) return 0;
  return Number(await rpc("q_insert_inverter_history_v2",
    { p_plant: inv.plantId, p_version: version, p_sn: inv.sn, p_rows: rows }) ?? 0);
}

export type Endpoint = "battery" | "grid" | "load" | "output";
export const ALL_ENDPOINTS: Endpoint[] = ["battery", "grid", "load", "output"];

/** Columns that come from `input` and are therefore fresh on a carried row too. */
export const INPUT_FIELDS = ["device_time", "pv_w", "pv_today_kwh", "pv_total_kwh"] as const;

/** Which readings columns each of the other four endpoints produces (extractReading). */
export const ENDPOINT_FIELDS: Record<Endpoint, string[]> = {
  battery: [
    "batt_power_w", "batt_w", "batt_soc", "batt_voltage_v", "batt_current_a", "batt_temp_c",
    "batt_chg_today_kwh", "batt_dischg_today_kwh", "batt_chg_total_kwh", "batt_dischg_total_kwh",
    "batt2_soc", "batt2_voltage_v", "batt2_current_a", "batt2_power_w", "batt2_temp_c",
  ],
  grid: [
    "grid_w", "grid_import_today_kwh", "grid_export_today_kwh", "grid_import_total_kwh",
    "grid_export_total_kwh", "grid_freq_hz", "grid_pf", "grid_volt_v", "grid_relay_status",
    "grid_volt_l2_v", "grid_volt_l3_v",
  ],
  load: ["load_w", "load_today_kwh", "load_total_kwh", "load_freq_hz"],
  output: ["output_w", "output_volt_v", "output_freq_hz", "output_volt_l2_v", "output_volt_l3_v"],
};

/**
 * Columns that must read NULL rather than the previous row's value when their
 * endpoint did not answer. The fallback below is right for counters, which only
 * grow, so the last known total beats a zero. It is wrong for an instantaneous
 * grid reading: copying one forward re-stamps a pre-outage 240 V with this
 * minute's device_time, so it cannot be told from a live measurement and the
 * grid goes on reading "present" through a blackout. Absent beats false, the
 * same rule the all-zero rows of 2026-09-10 were deleted under.
 */
export const NEVER_CARRY: ReadonlySet<string> = new Set([
  "grid_volt_v", "grid_volt_l2_v", "grid_volt_l3_v", "grid_relay_status", "grid_freq_hz",
]);

/** Battery columns that hold this instant's value, as opposed to growing totals. */
export const LIVE_BATTERY = [
  "batt_power_w", "batt_w", "batt_soc", "batt_voltage_v", "batt_current_a", "batt_temp_c",
  "batt2_soc", "batt2_voltage_v", "batt2_current_a", "batt2_power_w", "batt2_temp_c",
];

/** skipped: no input call at all; the row keeps the last upload's input fields too (SOLAR-612) */
export type Fetched = { inv: InverterInfo; raw: RawBundle; carried: boolean; fetched: Set<Endpoint>; sign: string | null; skipped?: boolean };

/** The carry rules that hold whatever input says: a known last upload, no outage, no hold, not too many carries. */
export function carryAllowed(inv: InverterInfo): boolean {
  const prev = inv.lastReading;
  if (!prev || prev.device_time == null) return false;
  if ((inv.carriedRun ?? 0) >= MAX_CARRIED_RUN) return false;
  // after a hold, read in full: a carry would copy the held figures forward unmarked (SOLAR-551)
  if (prev.held) return false;
  if (outageSignal(prev) !== null) return false;
  return true;
}

export function canCarry(inv: InverterInfo, inputTime: string | null): boolean {
  return carryAllowed(inv) && inputTime != null && inv.lastReading!.device_time === inputTime;
}

/**
 * SOLAR-612: a slow logger's next upload is not due yet, so the input check would only
 * find the last one again. A 5-minute logger is skipped for the first three minutes
 * after an upload and checked from the fourth. Loggers under 3 minutes are never skipped.
 */
export function uploadNotDue(inv: InverterInfo): boolean {
  const s = inv.uploadS;
  if (s == null || s < 180 || !carryAllowed(inv)) return false;
  return (inv.carriedRun ?? 0) + 2 < Math.floor(s / 60);
}

/** Which of the four non-input endpoints this minute needs, given the last row. */
export function wantEndpoints(prev: Record<string, unknown> | null | undefined, ts: number): Set<Endpoint> {
  if (!prev) return new Set(ALL_ENDPOINTS);
  const want = new Set<Endpoint>(["battery", "grid", "load"]);
  const age = (k: string) => ts - (Number(prev[k]) || 0); // null/absent -> very old
  if (age("output_fetched_ts") >= OUTPUT_EVERY_S) want.add("output");
  if (outageSignal(prev) !== null) want.add("output");
  return want;
}

export async function fetchInto(raw: RawBundle, eps: Endpoint[], sn: string, acc: Account): Promise<void> {
  const paths = realtimePaths(sn);
  const settled = await Promise.allSettled(eps.map((k) => apiGet(paths[k], acc)));
  eps.forEach((k, i) => {
    raw[k] = settled[i].status === "fulfilled" ? (settled[i] as PromiseFulfilledResult<any>).value : null;
  });
}

/** device_time on /realtime/input: when the datalogger last uploaded. */
export const inputTimeOf = (input: any): string | null =>
  (input && Array.isArray(input.pvIV) && input.pvIV[0] && input.pvIV[0].time) || null;

export async function fetchInverter(inv: InverterInfo, acc: Account, ts: number, sign: string | null, offGrid = false): Promise<Fetched> {
  if (uploadNotDue(inv)) {
    return { inv, raw: { input: null, grid: null, battery: null, load: null, output: null }, carried: true, fetched: new Set(), sign, skipped: true };
  }
  const paths = realtimePaths(inv.sn);
  const input = await apiGet(paths.input, acc).catch(() => null);
  const inputTime = inputTimeOf(input);
  const raw: RawBundle = { input, grid: null, battery: null, load: null, output: null };
  if (canCarry(inv, inputTime)) return { inv, raw, carried: true, fetched: new Set(), sign };

  const want = wantEndpoints(inv.lastReading, ts);
  await fetchInto(raw, [...want], inv.sn, acc);

  // The fresh grid payload shows an outage that the last row did not: read the far
  // side of the relay (and the load) now rather than at the next tier boundary.
  const late = (["output", "load"] as Endpoint[]).filter((k) => !want.has(k));
  if (late.length && !offGrid && outageSignal(extractReading(inv, raw, { battPositiveMeans: sign })) !== null) {
    await fetchInto(raw, late, inv.sn, acc);
    for (const k of late) want.add(k);
  }
  return { inv, raw, carried: false, fetched: want, sign };
}

/**
 * The readings row for this minute. Carried: the last row with fresh input fields.
 * Otherwise: fresh values for the endpoints fetched, the last row's for the rest,
 * load_w derived from the balance when load was not read.
 */
export function readingRow(f: Fetched, ts: number, tz: string): Record<string, unknown> {
  const fresh = extractReading(f.inv, f.raw, { battPositiveMeans: f.sign });
  const plant_id = f.inv.plantId ?? null;
  const prev = f.inv.lastReading ?? {};
  // the plant's midnight passed since the last row: its today counters stay behind (SOLAR-648)
  const turned = dayTurned(tz, ts, prev);
  if (f.carried) {
    const row: Record<string, unknown> = { ...prev, ts, plant_id, sn: f.inv.sn, status: fresh.status };
    for (const k of TODAY_COUNTERS) row[k] = fromPrev(k, prev[k], turned);
    if (!f.skipped) for (const k of INPUT_FIELDS) row[k] = fresh[k];
    row.carried = true;
    clearYesterday(row, tz);
    return row;
  }
  // `fetched` says which endpoints were ASKED for, not which answered: fetchInto
  // stores null for a rejected call and leaves the endpoint in the set. Reading
  // `fresh` for one of those takes extractReading's defaults, which are 0 for every
  // quantity but grid volts — so a single failed call wrote 0 W / 0 % / 0 V into an
  // otherwise good minute, indistinguishable from a real reading. Ask whether the
  // payload actually arrived, and fall back to the previous row when it did not.
  const got = (ep: Endpoint) => f.fetched.has(ep) && f.raw[ep] != null;
  const row: Record<string, unknown> = { ts, plant_id, sn: f.inv.sn, status: fresh.status, carried: false };
  for (const k of INPUT_FIELDS) row[k] = fresh[k];
  for (const ep of ALL_ENDPOINTS) {
    const ok = got(ep);
    for (const col of ENDPOINT_FIELDS[ep]) {
      row[col] = ok ? (fresh[col] ?? null)
               : NEVER_CARRY.has(col) ? null
               : fromPrev(col, prev[col], turned);
    }
  }
  // A battery answer can arrive whole but empty: 0 V, 0 A, 0 % and 0 °C beside real
  // lifetime totals (143 rows on 495944 and 538820 in October, up to 18 minutes in a
  // row, SOLAR-231). A battery never reads 0 V, so its live fields are unknown that
  // minute, not zero. Totals only grow and stay as read.
  if (got("battery") && Number(fresh.batt_voltage_v) === 0) {
    for (const col of LIVE_BATTERY) row[col] = null;
  }
  // Only stamp the tier clocks when the read succeeded. Stamping on failure told
  // wantEndpoints the value was fresh, so a failed load or output was not retried
  // for another 5 or 10 minutes.
  row.load_fetched_ts = got("load") ? ts : (prev.load_fetched_ts ?? null);
  row.output_fetched_ts = got("output") ? ts : (prev.output_fetched_ts ?? null);
  if (!got("load")) {
    // grid + = import, batt + = charging (DATA_PIPELINE §9A); counters stay carried
    row.load_w = Math.max(0, Math.round(num(row.pv_w) + num(row.grid_w) - num(row.batt_w)));
  }
  clearYesterday(row, tz);
  return row;
}

/** One login's minute as poll_commit_batch takes it (0268); poll_commit_v2 takes the same as p_*. */
export type CommitRow = {
  account: string;
  versions: Record<string, number | null>;
  readings: Record<string, unknown>[];
  strings: Record<string, unknown>[];
  agg: Record<string, unknown>[];
  meta: unknown[];
  inverters: { sn: string; plant_id: number | null; account_id: string }[];
  access: string | null;
  expires: number | null;
};
/** What the save answered for one login. */
export type Committed = { readings: number; strings: number; plants: number[]; gaps: number[]; refused?: number[] };

/**
 * A read minute: the result so far, the row to save (null: nothing to save, `result` is
 * final) and `finish`, which takes the save's answer and runs what follows a save (plant
 * detection on refresh minutes, today's temperatures).
 */
export type ReadMinute = { result: AccountResult; row: CommitRow | null; finish: (c: Committed) => Promise<AccountResult> };

export type ReadOptions = {
  /** the login's cached inverters, read beforehand for many logins at once (inverters_cached_many) */
  cached?: InverterInfo[];
  /**
   * false: another read of the same login this minute does the plant sync (a login read
   * plant by plant on several seconds, 0268's read_second). Default true.
   */
  lead?: boolean;
  /** the login's live inverter list, shared by its reads this minute (default getInverters) */
  liveList?: () => Promise<InverterInfo[]>;
};

/** Read one login's plants for one minute and save it with poll_commit_v2. */
export async function pollAccount(acc: Account, jobs: PlantJob[], ts: number): Promise<AccountResult> {
  const read = await readAccount(acc, jobs, ts);
  if (!read.row) return read.result;
  const r = read.row;
  // The whole minute in one transaction (migration 0030): readings and strings
  // last-write-wins, agg_minute first-write-wins with gap detection, meta, the
  // inverter mirror and the account's token.
  const committed = await rpc<Committed>("poll_commit_v2", {
    p_versions: r.versions, p_account: r.account, p_ts: ts, p_readings: r.readings, p_strings: r.strings,
    p_agg: r.agg, p_meta: r.meta, p_inverters: r.inverters, p_access: r.access, p_expires: r.expires,
  });
  return read.finish(committed);
}

/** Read every inverter of a login's plants for one minute; the save is the caller's. */
export async function readAccount(acc: Account, jobs: PlantJob[], ts: number, opts: ReadOptions = {}): Promise<ReadMinute> {
  const result = emptyResult(acc);
  const done = (): ReadMinute => ({ result, row: null, finish: async () => result });
  const lead = opts.lead ?? true;
  const callsAtStart = apiCallCounts.get(acc.id) ?? 0;
  const wanted = new Set(jobs.map((j) => j.plantId));

  // Inverter list: from the cache, unless it is this account's refresh minute or
  // the cache is empty (first minute after linking). On a refresh minute the live
  // list is merged with the cache so each inverter keeps its last row and carry
  // run: the freshness gate and tiering then apply on refresh minutes too.
  // The plant list is re-read hourly so a plant added at SunSynk starts logging.
  // A cached inverter with no status (linking seeds private.inverters without meta)
  // also takes the live list: meta is written only on a fresh minute, and a slave
  // that uploads off the refresh minute would otherwise read status 0 for good
  // (SOLAR-168).
  const refreshMinute = isListMinute(acc.id, ts);
  const plantsMinute = lead && isPlantsMinute(acc.id, ts);
  const cached = opts.cached ?? await getInvertersCached(acc);
  const noStatus = cached.some((c) => c.status == null && wanted.has(Number(c.plantId)));
  let all = cached;
  if (refreshMinute || noStatus || !cached.length) {
    result.listRefreshed = true;
    const bySn = new Map(cached.map((c) => [c.sn, c]));
    all = (await (opts.liveList ?? (() => getInverters(acc)))()).map((inv) => {
      const c = bySn.get(inv.sn);
      return c ? { ...inv, lastReading: c.lastReading, carriedRun: c.carriedRun, uploadS: c.uploadS } : inv;
    });
  }
  if (isShareAccount(acc)) {
    // The share login sees every shared plant, claimed or not: only claimed ones poll,
    // and nothing is linked to the login's own user (SOLAR-310).
    if (plantsMinute) {
      try { console.log(`share sync:`, JSON.stringify(await shareSync(acc))); }
      catch (e) {
        console.warn(`share sync failed:`, e instanceof Error ? e.message : e);
        noteError("share_sync_failed", e, { hourly: true });
      }
    }
  } else if (plantsMinute || (lead && !cached.length)) {
    // Since the billing switch-over (0246) only chosen plants are read: a plant new on the
    // login waits to be chosen. Before it (no versions), it is read from this minute on.
    try {
      const plants = await syncPlants(acc);
      if (jobs.every((j) => j.version == null)) for (const p of plants) wanted.add(p.id);
    } catch (e) {
      console.warn(`plant refresh failed for ${acc.id}:`, e instanceof Error ? e.message : e);
      noteError("plant_refresh_failed", e, { user: acc.user_id, hourly: true });
    }
  }
  result.listCalls = callsSince(acc, callsAtStart);
  const inverters = all.filter((inv) => inv.plantId != null && wanted.has(Number(inv.plantId)));
  const skipped = all.filter((inv) => !inverters.includes(inv)).map((inv) => inv.sn);
  if (skipped.length) result.skipped = skipped;
  result.apiCalls = callsSince(acc, callsAtStart);
  if (!inverters.length) return done();
  result.inverters = inverters.length;

  // Battery sign per plant (0041): the plant's own answer, or the fleet default
  // until detection has had enough data to decide.
  const signOf = new Map(jobs.map((j) => [j.plantId, j.battPositiveMeans]));
  // Off-grid plants (has_grid = false, 0042): the relay is open by design, so the
  // early far-side reads would fire every minute for nothing. Unknown (null) counts
  // as off-grid here too, so a failed plant_config read does not start them up.
  const offGrid = new Set(jobs.filter((j) => j.hasGrid !== true).map((j) => j.plantId));
  const perInv = await Promise.all(inverters.map((inv) =>
    fetchInverter(inv, acc, ts, signOf.get(Number(inv.plantId)) ?? null, offGrid.has(Number(inv.plantId)))));
  // Today's temperatures for the inverters whose minute this is and whose logger has sent
  // something new: started now, awaited at the end so the readings commit first. A
  // failure costs only this round.
  const tzOf = new Map(jobs.map((j) => [j.plantId, j.timezone]));
  const versionOf = new Map(jobs.map((j) => [j.plantId, j.version]));
  const due = perInv.filter((f) => !f.carried && inputTimeOf(f.raw.input) != null
    && Math.floor(ts / 60) % TEMP_EVERY_MIN === tempMinute(f.inv.sn)).map((f) => f.inv);
  const tempsDone = Promise.allSettled(due.map((inv) => bankTodayTemps(inv, acc, tzOf.get(Number(inv.plantId)) ?? "Africa/Johannesburg",
    versionOf.get(Number(inv.plantId)) ?? null)));
  const carried = perInv.filter((f) => f.carried).map((f) => f.inv.sn);
  if (carried.length) result.carried = carried;
  // Endpoints whose value on this row came from the previous one — whether they were
  // never asked for (tiering) or asked for and did not answer. Both mean the same
  // thing to a reader of the data, and lumping them together is what kept a failing
  // endpoint invisible: it looked identical to a deliberate skip.
  const arrived = (f: Fetched, k: Endpoint) => f.fetched.has(k) && f.raw[k] != null;
  const tiered = Object.fromEntries(perInv
    .filter((f) => !f.carried && ALL_ENDPOINTS.some((k) => !arrived(f, k)))
    .map((f) => [f.inv.sn, ALL_ENDPOINTS.filter((k) => !arrived(f, k))]));
  if (Object.keys(tiered).length) result.tiered = tiered;

  // `input` is the anchor: it carries device_time, the only field that says whether
  // this minute is a fresh sample or a repeat of the last one. Without it there is
  // nothing to date the row by, the freshness gate is blind, and PV would be stored
  // as 0 W — which is what put seven all-zero minutes into 10 Sep. On a chart those
  // read as a genuine drop to zero rather than as absent data, and `recover` cannot
  // repair them, because the minute is present, only wrong. Leave it absent instead
  // and let recover bank it from the inverter's own uploads. Absent beats false.
  // (A carry has no input payload by design — it dates itself from the previous row.)
  // An input that answers without a time is no anchor either: a logger gone quiet
  // gets that from SunSynk, with zeros on the other endpoints (2504193036 on
  // 31 Oct, 12:59-16:03: load 0 for three hours, SOLAR-296).
  const noAnchor = (f: Fetched) => !f.carried && inputTimeOf(f.raw.input) == null;
  const usable = perInv.filter((f) => !noAnchor(f));
  const noData = perInv.filter(noAnchor).map((f) => f.inv.sn);
  if (noData.length) result.noData = noData;
  // Every inverter silent: nothing to commit, and no agg row either. The minute is
  // left absent so recover can bank it from the cloud later.
  if (!usable.length) {
    result.apiCalls = callsSince(acc, callsAtStart);
    return done();
  }

  // A row that mixes two uploads keeps the last balanced row's power figures (SOLAR-551).
  const readings = usable.map((f) => {
    const row = readingRow(f, ts, tzOf.get(Number(f.inv.plantId)) ?? "Africa/Johannesburg");
    holdLastGood(row, f.inv.lastReading);
    return row;
  });
  // Strings come from input, which is always fetched, so they are fresh every minute.
  const strings = usable.flatMap(({ inv, raw }) =>
    extractStrings(inv, raw).map((s) => ({ ts, plant_id: inv.plantId ?? null, ...s }))
  );
  // Meta reads battery capacity off the battery payload; a carried inverter has no
  // battery payload this minute, so leave its meta row alone rather than zero it.
  // (A tiered inverter always has one: battery is never tiered.)
  const meta = usable
    .map(({ inv, raw, carried }, i) => (carried ? null : extractMeta(inv, raw, ts, i)))
    .filter((m) => m !== null);

  // One aggregate row per plant on this account. A plant with an inverter left out
  // above sums only the rest, so its row is marked partial: recover replaces it
  // from the inverters' own uploads, where it would skip a whole row (SOLAR-296).
  const plantIds = [...new Set(readings.map((r) => r.plant_id as number))];
  const short = new Set(perInv.filter(noAnchor).map((f) => Number(f.inv.plantId)));
  const agg = plantIds.map((plantId) => ({
    plant_id: plantId,
    ...aggregate(readings.filter((r) => r.plant_id === plantId) as any),
    partial: short.has(Number(plantId)),
  }));

  // fetchInverter may have refreshed the token, so read it off `acc` here rather than from
  // the row we started with.
  const row: CommitRow = {
    account: acc.id,
    versions: Object.fromEntries(jobs.map((j) => [String(j.plantId), j.version])),
    readings, strings, agg, meta,
    inverters: inverters.map((i) => ({ sn: i.sn, plant_id: i.plantId ?? null, account_id: acc.id })),
    access: acc.access_token,
    expires: acc.access_expires_at,
  };
  result.apiCalls = callsSince(acc, callsAtStart);
  return { result, row, finish: (committed) => afterCommit(committed) };

  async function afterCommit(committed: Committed): Promise<AccountResult> {
    result.commitMs = Date.now() - ts * 1000;
    if (committed.refused?.length) result.refused = committed.refused;
    result.readings = committed.readings;
    result.strings = committed.strings;
    result.plants = committed.plants;
    result.gapRecorded = committed.gaps;

    // Plants still on the fleet default: let the database try to settle the battery
    // sign from what has been stored so far. Cheap, and only on refresh minutes.
    if (refreshMinute) {
      for (const pid of plantIds) {
        // Battery present? Grid present? Decided from the first day of readings (0042).
        try {
          const f = await rpc("plant_features_detect", { p_plant: pid }) as Record<string, unknown>;
          if (f?.decided) console.log(`features for plant ${pid}:`, JSON.stringify(f));
        } catch (e) {
          console.warn(`plant_features_detect ${pid}:`, e instanceof Error ? e.message : e);
        }
        // One battery pack or one per inverter? Decided from matching charge and voltage (0065).
        try {
          const b = await rpc("battery_banks_detect", { p_plant: pid }) as Record<string, unknown>;
          if (b?.decided && b.detected !== b.was) console.log(`battery banks for plant ${pid}:`, JSON.stringify(b));
        } catch (e) {
          console.warn(`battery_banks_detect ${pid}:`, e instanceof Error ? e.message : e);
        }
        if (signOf.get(pid) != null) continue;
        try {
          const d = await rpc("batt_sign_detect", { p_plant: pid, p_default: DEFAULT_BATT_POSITIVE_MEANS }) as Record<string, unknown>;
          if (d?.decided) console.log(`batt sign for plant ${pid}:`, JSON.stringify(d));
        } catch (e) {
          console.warn(`batt_sign_detect ${pid}:`, e instanceof Error ? e.message : e);
        }
      }
    }

    if (due.length) {
      const got = await tempsDone;
      result.temps = Object.fromEntries(due.map((inv, i) => [inv.sn, got[i].status === "fulfilled"
        ? (got[i] as PromiseFulfilledResult<number>).value : String((got[i] as PromiseRejectedResult).reason)]));
    }
    result.apiCalls = callsSince(acc, callsAtStart);
    return result;
  }
}
