// One step of History's queue (SOLAR-686), as history.take hands it out, and the calls a step
// makes to the database: every write carries the step's claim (H6) and goes through
// public.history_jobs, which checks the claim, the plant's version, that it is read now and not
// being deleted (H8).
import { db } from "../_shared/db.ts";
import type { Account, VendorPlantId } from "../_shared/brands/index.ts";

export type Step = {
  step: "day" | "totals";
  id: number;
  claim: string;
  plant: number;
  version: number | null;
  kind: "minutes" | "extras" | "totals";
  day: string | null;
  why: "import" | "gap" | "check" | null;
  tries: number;
  grid_only: boolean;
  full: boolean;
  feed: boolean;
  calls: number;
  timezone: string;
  brand: string;
  vendor_plant_id: VendorPlantId;
  login: Account;
};

/** How a step ended: history.step_done's results (H7). */
export type Result = { result: "ok" | "failed" | "throttled" | "wait" | "refused"; note?: string; banked?: number };

export async function jobs<T = any>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await db.rpc("history_jobs", { p_cmd: cmd, p_args: args });
  if (error) throw new Error(`history_jobs ${cmd}: ${error.message}`);
  return data as T;
}

/** A write the database refused: the plant is not read now, or the claim was lost. Not an error. */
export const isRefused = (e: unknown) => /is not read now/.test(String(e instanceof Error ? e.message : e));

/** The step's claim on the write (H6); a refused write marks the step so it stops. */
export async function write(s: Step & { refused?: boolean }, cmd: "minutes" | "extras" | "totals", args: Record<string, unknown>) {
  try {
    return Number(await jobs(cmd, { step: s.step, id: s.id, claim: s.claim, ...args }) ?? 0);
  } catch (e) {
    if (!isRefused(e)) throw e;
    s.refused = true;
    return 0;
  }
}
