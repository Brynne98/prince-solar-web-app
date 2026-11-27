// The per-inverter reading of one login for one minute (SOLAR-656: moved out of poll/index.ts
// so another host can run it). pollAccount reads every inverter of the login's plants and
// saves the minute through the database handle in db.ts (poll_commit_v2). The edge `poll`
// function calls it per login; what it does is described there.
import { noteError } from "./errors.ts";
import { rpc } from "./db.ts";
import { type Account, brandOf, faultOf, type Fetched, type InverterInfo } from "./brands/index.ts";
import { getInvertersCached, liveInverters, type PlantJob } from "./plants.ts";
import { holdLastGood } from "../poll/hold.mts";
// The inverter and plant lists change rarely: the plant-sync job re-reads them on each
// login's own minutes (sidejobs.ts, R18) and the reader serves them from
// private.inverters/meta (0031).

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
  /** inverter list re-read from the brand this minute (else served from cache) */
  listRefreshed: boolean;
  /** the brand requests spent on the inverter / plant lists this minute (0, 1 or 2+) */
  listCalls: number;
  /** the brand requests this account cost this minute, retries included */
  apiCalls: number;
  /** ms after the minute that poll_commit_v2 answered: when the readings became visible */
  commitMs?: number;
  error?: string;
  needsRelink?: boolean;
  signInFailed?: boolean;
  /** whose fault the error was (brands/types.ts faultOf) */
  fault?: "relink" | "sign_in" | "vendor" | "ours";
};

export const emptyResult = (acc: Account): AccountResult => ({
  account: acc.id, inverters: 0, readings: 0, strings: 0, plants: [], gapRecorded: [],
  listRefreshed: false, listCalls: 0, apiCalls: 0,
});

/**
 * A login whose read or save threw: marked on its row (needs_reconnect when its refresh token is
 * dead), logged, and noted for PostHog unless the owner must fix it. Returns its result.
 */
export async function accountFailed(acc: Account, jobs: { plantId: number }[], e: unknown): Promise<AccountResult> {
  const msg = e instanceof Error ? e.message : String(e);
  const fault = faultOf(e);
  const needsRelink = fault === "relink";
  await rpc("account_mark", {
    p_account: acc.id, p_status: needsRelink ? "needs_reconnect" : "ok", p_error: msg,
  }).catch(() => {});
  console.error(`poll: account ${acc.id} failed:`, msg);
  // A dead login is the owner's to fix and is mailed to them; the rest are ours or the brand's.
  if (!needsRelink) {
    const kind = fault === "sign_in" ? "sign_in" : fault;
    for (const j of jobs) noteError(`account_failed_${kind}`, e, { user: acc.user_id, plant: j.plantId, hourly: true });
  }
  return { ...emptyResult(acc), error: msg, fault, ...(needsRelink ? { needsRelink } : {}),
    ...(fault === "sign_in" ? { signInFailed: true } : {}) };
}

/**
 * How a login's minute went, for email_poll_step (0102), or null to leave it out. the brand's
 * fault and ours are told apart so our own outage is never mailed as the brand's: our errors
 * are rpc failures ("fn: message"); a dead login is left out, and so is one we could not
 * sign in (SOLAR-451): no read was made, so it says nothing about the inverter.
 */
export function emailOutcome(r: AccountResult): { account: string; outcome: string } | null {
  if (r.needsRelink || r.signInFailed) return null;
  return {
    account: r.account,
    outcome: r.error ? (r.fault === "vendor" ? "vendor" : "ours")
           : r.inverters > 0 && r.readings === 0 ? "vendor" : "ok",
  };
}

/** the brand requests made for this account since `since`. */
const callsSince = (acc: Account, since: number) => brandOf(acc.brand).callCount(acc) - since;



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
  const brand = brandOf(acc.brand);
  const callsAtStart = brand.callCount(acc);
  const wanted = new Set(jobs.map((j) => j.plantId));

  // Inverter list: from the cache, unless it is this account's refresh minute or
  // the cache is empty (first minute after linking). On a refresh minute the live
  // list is merged with the cache so each inverter keeps its last row and carry
  // run. A cached inverter with no status (linking seeds private.inverters without meta)
  // also takes the live list: meta is written only on a fresh minute, and a slave
  // that uploads off the refresh minute would otherwise read status 0 for good
  // (SOLAR-168).
  // The list itself is re-read by the plant-sync job (R18); the reader reads it only when it
  // has nothing cached (the first minute after a link) or an inverter has no status yet.
  const cached = opts.cached ?? await getInvertersCached(acc);
  const noStatus = cached.some((c) => c.status == null && wanted.has(Number(c.plantId)));
  const uncached = [...wanted].some((p) => !cached.some((c) => Number(c.plantId) === p));
  let all = cached;
  if (noStatus || uncached || !cached.length) {
    result.listRefreshed = true;
    const bySn = new Map(cached.map((c) => [c.sn, c]));
    all = (await (opts.liveList ?? (() => liveInverters(acc)))()).map((inv) => {
      const c = bySn.get(inv.sn);
      return c ? { ...inv, lastReading: c.lastReading, carriedRun: c.carriedRun, uploadS: c.uploadS } : inv;
    });
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
    brand.readNow(inv, acc, ts, { sign: signOf.get(Number(inv.plantId)) ?? null, offGrid: offGrid.has(Number(inv.plantId)) })));
  const tzOf = new Map(jobs.map((j) => [j.plantId, j.timezone]));
  const carried = perInv.filter((f) => f.carried).map((f) => f.inv.sn);
  if (carried.length) result.carried = carried;
  // Endpoints whose value on this row came from the previous one — whether they were
  // never asked for (tiering) or asked for and did not answer. Both mean the same
  // thing to a reader of the data, and lumping them together is what kept a failing
  // endpoint invisible: it looked identical to a deliberate skip.
  const tiered = Object.fromEntries(perInv
    .map((f) => [f.inv.sn, brand.missingParts(f)] as const).filter(([, m]) => m.length));
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
  // gets that from the brand, with zeros on the other endpoints (2504193036 on
  // 31 Oct, 12:59-16:03: load 0 for three hours, SOLAR-296).
  const noAnchor = (f: Fetched) => !brand.anchored(f);
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
    const row = brand.readingRow(f, ts, tzOf.get(Number(f.inv.plantId))!);
    holdLastGood(row, f.inv.lastReading);
    return row;
  });
  // Strings come from input, which is always fetched, so they are fresh every minute.
  const strings = usable.flatMap((f) =>
    brand.stringRows(f).map((s) => ({ ts, plant_id: f.inv.plantId ?? null, ...s }))
  );
  // Meta reads battery capacity off the battery payload; a carried inverter has no
  // battery payload this minute, so leave its meta row alone rather than zero it.
  // (A tiered inverter always has one: battery is never tiered.)
  const meta = usable
    .map((f, i) => brand.metaRow(f, ts, i))
    .filter((m) => m !== null);

  // One aggregate row per plant on this account. A plant with an inverter left out
  // above sums only the rest, so its row is marked partial: recover replaces it
  // from the inverters' own uploads, where it would skip a whole row (SOLAR-296).
  const plantIds = [...new Set(readings.map((r) => r.plant_id as number))];
  const short = new Set(perInv.filter(noAnchor).map((f) => Number(f.inv.plantId)));
  const agg = plantIds.map((plantId) => ({
    plant_id: plantId,
    ...brand.aggregate(readings.filter((r) => r.plant_id === plantId)),
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

    result.apiCalls = callsSince(acc, callsAtStart);
    return result;
  }
}
