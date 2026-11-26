// One interface for every inverter brand (SOLAR-681 R15). Code outside brands/ calls a brand
// only through this interface (brands/index.ts gives the adapter for a login's brand) and never
// names one. The first adapter is in brands/ beside this file.
//
// Two kinds of plant id (R12): PlantId is ours, the key every table uses; VendorPlantId is the
// brand's own, text, used only in calls to the brand. Branded types keep one from being passed
// where the other is wanted.

export type PlantId = number & { readonly __plantId: unique symbol };
export type VendorPlantId = string & { readonly __vendorPlantId: unique symbol };
export const vendorPlantId = (v: string | number) => String(v) as VendorPlantId;

/** A linked login, as the reader and the plant sync use it. Tokens are cached on the row. */
export type Account = {
  id: string;
  user_id: string;
  username: string;
  brand: string;
  access_token: string | null;
  access_expires_at: number | null;
  /** aborted: the read this login is in was dropped: no more calls start for it */
  signal?: AbortSignal;
};

export type TokenSet = { access_token: string; refresh_token: string; expires_in: number };

/** A plant as the brand lists it for a login. */
export type VendorPlant = { vendorId: VendorPlantId; name: string };
export type VendorPlantDetail = { vendorId: VendorPlantId; timezone: string | null; lat: number | null; lon: number | null };

/** An inverter as the brand lists it, plus what the reader carries between minutes. */
export interface InverterInfo {
  sn: string;
  alias?: string;
  /** our plant id; set from vendorPlantId by the plant mapping (plants.ts) */
  plantId?: number | null;
  /** the brand's plant id, from the brand's own list */
  vendorPlantId?: VendorPlantId;
  plantName?: string | null;
  model?: string;
  status?: number | string;
  gsn?: string;
  soft?: string;
  hmi?: string;
  commType?: string;
  /** the last row stored for this inverter (cache), for carry rules */
  lastReading?: Record<string, unknown> | null;
  carriedRun?: number;
  uploadS?: number | null;
}

/** The brand refused the username or password at sign-in. */
export class LoginRejected extends Error {}

/** Sign-in failed for a reason that says nothing about the login (timeout, 5xx, network). */
export class SignInFailed extends Error {}

/** The login's stored token is dead; the owner must reconnect. */
export class RelinkNeeded extends Error {
  constructor(public accountId: string, reason: string) {
    super(`account ${accountId} needs re-link: ${reason}`);
  }
}

/**
 * A call to the brand failed on the brand's side (R15): `rate` (still rate-limited after the
 * retries), `vendor_down` (5xx, timeout, network), `auth` (refused token), `refused` (any other
 * HTTP error). Every other error is ours.
 */
export type VendorErrorKind = "rate" | "vendor_down" | "auth" | "refused";
export class VendorError extends Error {
  constructor(public kind: VendorErrorKind, message: string) {
    super(message);
  }
}

/** Whose fault a failed login was, for alerts (email_poll_step outcomes). */
export function faultOf(e: unknown): "relink" | "sign_in" | "vendor" | "ours" {
  if (e instanceof RelinkNeeded) return "relink";
  if (e instanceof SignInFailed) return "sign_in";
  if (e instanceof VendorError) return "vendor";
  return "ours";
}

/** One minute of one inverter, read from the brand. Opaque outside the adapter except as listed. */
export type Fetched = {
  inv: InverterInfo;
  /** the brand's payloads; the adapter's own shape */
  raw: unknown;
  /** the row repeats the last upload (nothing new from the logger) */
  carried: boolean;
  /** no call was made: the logger's next upload is not due */
  skipped?: boolean;
  /** battery sign the row was read with */
  sign: string | null;
};

export type ReadOptions = { sign: string | null; offGrid: boolean };

export interface Brand {
  code: string;
  /** shown on screens and in mail */
  displayName: string;

  // logins
  /** Username and password to tokens. Throws LoginRejected or SignInFailed. */
  signIn(username: string, password: string): Promise<TokenSet & { expires_at: number }>;
  /** the company login owners share plants with (claims) */
  isShare(acc: Pick<Account, "username">): boolean;
  shareLogin(): { username: string; password: string } | null;
  /** a login from the environment, linked once to BOOTSTRAP_USER_EMAIL (old single-site setups) */
  bootstrapLogin(): { username: string; password: string } | null;

  // lists
  /** The whole list or a throw: never a part (R9). */
  listPlants(acc: Account): Promise<VendorPlant[]>;
  plantDetail(acc: Account, id: VendorPlantId): Promise<VendorPlantDetail>;
  listInverters(acc: Account): Promise<InverterInfo[]>;

  // reading now
  readNow(inv: InverterInfo, acc: Account, ts: number, opts: ReadOptions): Promise<Fetched>;
  /** the logger sent something dated: the row can be stored */
  anchored(f: Fetched): boolean;
  /** which parts of a non-carried read did not arrive (shown in the poll log) */
  missingParts(f: Fetched): string[];
  /** a reading looks like a grid outage */
  outage(row: Record<string, unknown>): string | null;
  readingRow(f: Fetched, ts: number, tz: string): Record<string, unknown>;
  stringRows(f: Fetched): Record<string, unknown>[];
  metaRow(f: Fetched, ts: number, ord: number): Record<string, unknown> | null;
  aggregate(rows: Record<string, unknown>[]): Record<string, unknown>;
  defaultBatterySign: string;
  /** today's inverter temperature rows so far (inverter_history rows) */
  todayTemps(inv: InverterInfo, acc: Account, tz: string): Promise<Record<string, unknown>[]>;

  // history (History rebuilds this in step 3; recover and sync-plant-energy call it)
  history: BrandHistory;

  // calls
  /** calls made per login since start, retries included */
  callCount(acc: Account): number;
  /** saves the call counts to the database (one write) */
  saveCalls(run?: { shard: number; ms: number; plants: number }): Promise<void>;
}

/** One minute of the plant from its inverters' history (all of them summed). */
export type SpineRow = {
  pv_w: number | null; load_w: number | null; batt_w: number | null; grid_w: number | null; soc: number | null;
};
/** How the brand's plant feed scales against our own sums. */
export type FeedScale = { pv: number; batt: number; grid: number; load: number };

/**
 * Past days from the brand. The day shapes (`any` here) are the adapter's own: they go back
 * into the adapter's rows/spine functions and are not read outside it.
 */
export interface BrandHistory {
  /** one inverter's day of power series; `web` tries the brand's faster host first */
  inverterDay(acc: Account, sn: string, day: string, web?: boolean): Promise<any>;
  /** one inverter's day of temperatures, volts and Hz */
  inverterExtras(acc: Account, sn: string, day: string, gridOnly?: boolean): Promise<any>;
  /** inverter_history rows from either day shape */
  historyRows(day: any, dayStart: number): Record<string, unknown>[];
  /** the plant's minute spine from its inverters' days */
  plantSpine(days: any[], dayStart: number): Map<number, SpineRow>;
  /** the plant's own day feed (5-minute buckets), null when the brand has none */
  plantDay(acc: Account, id: VendorPlantId, day: string): Promise<any | null>;
  /** scale of the plant feed against our own buckets */
  feedScale(feed: any, ours: any[]): FeedScale;
  /** our agg_minute rows in the plant feed's buckets */
  bucketsOf(aggRows: any[]): any[];
  /** plant_energy rows for a month (daily) or a year (monthly) */
  monthRows(acc: Account, id: VendorPlantId, year: number, month1: number, gridMul?: number): Promise<any[]>;
  yearRows(acc: Account, id: VendorPlantId, year: number, gridMul?: number): Promise<any[]>;
  /** calls still rate-limited after retries, per login (the history queue backs off on them) */
  throttled(acc: Account): number;
}
