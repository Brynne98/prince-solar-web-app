// The database handle the brand and reading code writes through (SOLAR-656).
//
// Today every edge function uses PostgREST (supabase-js, service role): `postgrest` below.
// A host with a direct Postgres connection (poller v3: lanes, the worker) gives its own
// handle to useDb() once at start; plants.ts and poller.ts then call through it. Only
// what those two need is here: database functions by name, and the two plant settings
// calls syncPlants makes (through the plants part's functions, SOLAR-681 R2).
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
};

// Reads the reader makes every minute: a gateway that answered 502/503/504 is asked once more,
// so one hiccup does not cost the minute (SOLAR-681 R22: 4 plant-minutes in 14,500 were lost to
// "invalid response from the upstream server"). Writes are not retried here.
const READS = new Set(["inverters_cached", "inverters_cached_many", "poll_jobs_v2", "plants_of_login", "plant_vendor",
  "account_refresh_get"]);
const gatewayFailed = (status: number) => status === 502 || status === 503 || status === 504;

export const postgrest: Db = {
  async rpc(fn, args) {
    let { data, error, status } = await db.rpc(fn, args);
    if (error && READS.has(fn) && gatewayFailed(status)) ({ data, error } = await db.rpc(fn, args));
    if (error) throw new Error(`${fn}: ${error.message}`);
    return data;
  },
  async configuredPlants(ids) {
    const { data, error } = await db.rpc("plants_configured", { p_plants: ids });
    if (error) throw new Error(`plants_configured: ${error.message}`);
    return (data ?? []).map((r: any) => Number(r));
  },
};

let current: Db = postgrest;

/** Send the shared code's database calls through `handle` from now on. */
export const useDb = (handle: Db) => { current = handle; };

/** The handle in use. */
export const dbHandle = (): Db => current;

/** A database function through the handle in use. Throws `fn: message`. */
export const rpc = <T = any>(fn: string, args: Record<string, unknown> = {}): Promise<T> => current.rpc<T>(fn, args);
