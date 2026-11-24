// The database handle the SunSynk and reading code writes through (SOLAR-656).
//
// Today every edge function uses PostgREST (supabase-js, service role): `postgrest` below.
// A host with a direct Postgres connection (poller v3: lanes, the worker) gives its own
// handle to useDb() once at start; sunsynk.ts and poller.ts then call through it. Only
// what those two need is here: database functions by name, and the two plant_config
// reads and writes syncPlants makes.
import { createClient } from "jsr:@supabase/supabase-js@2.118.0";

export const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

export type Db = {
  /**
   * A database function by name, named arguments. Throws `fn: message` on failure. Answers
   * as PostgREST does: a set-returning function as an array (one row too), a scalar as the
   * value, json/jsonb as parsed. JS arrays go to jsonb or array parameters by the
   * function's declared type, so a direct handle reads pg_proc (proretset, argument types).
   */
  rpc<T = any>(fn: string, args: Record<string, unknown>): Promise<T>;
  /** Which of these plants already have a plant_config row. Throws `plant_config: message`. */
  configuredPlants(ids: number[]): Promise<number[]>;
  /** Drop the history bookmarks of plants that are not read. Throws the database's message. */
  clearBookmarks(ids: number[]): Promise<void>;
};

export const postgrest: Db = {
  async rpc(fn, args) {
    const { data, error } = await db.rpc(fn, args);
    if (error) throw new Error(`${fn}: ${error.message}`);
    return data;
  },
  async configuredPlants(ids) {
    const { data, error } = await db.from("plant_config").select("plant_id").in("plant_id", ids);
    if (error) throw new Error(`plant_config: ${error.message}`);
    return (data ?? []).map((r: any) => Number(r.plant_id));
  },
  async clearBookmarks(ids) {
    const { error } = await db.from("plant_config").update({ backfill_next: null, backfill_until: null, temp_next: null }).in("plant_id", ids);
    if (error) throw new Error(String(error.message));
  },
};

let current: Db = postgrest;

/** Send the shared code's database calls through `handle` from now on. */
export const useDb = (handle: Db) => { current = handle; };

/** The handle in use. */
export const dbHandle = (): Db => current;

/** A database function through the handle in use. Throws `fn: message`. */
export const rpc = <T = any>(fn: string, args: Record<string, unknown> = {}): Promise<T> => current.rpc<T>(fn, args);
