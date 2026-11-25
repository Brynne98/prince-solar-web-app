// directDb (_shared/pgdb.ts) answers as PostgREST does (SOLAR-656). LOCAL stack only; it
// writes nothing that is not rolled back by the functions themselves (reads, plus one
// sunsynk_tally and one account_mark on a throwaway row, removed at the end).
//   SUPABASE_URL=http://127.0.0.1:<api port> SUPABASE_SERVICE_ROLE_KEY=<key> DB_URL=postgresql://...:<db port>/postgres \
//   npx deno@2.5.6 run -A --node-modules-dir=none scripts/pgdb-parity-test.ts
// Exit code decides.
import { postgrest } from "../supabase/functions/_shared/db.ts";
import { directDb } from "../supabase/functions/_shared/pgdb.ts";

const direct = directDb(Deno.env.get("DB_URL")!);
let failed = 0;
const same = (label: string, a: unknown, b: unknown) => {
  const ja = JSON.stringify(a), jb = JSON.stringify(b);
  if (ja === jb) console.log(`PASS  ${label}`);
  else { failed++; console.log(`FAIL  ${label}\n  postgrest: ${ja.slice(0, 300)}\n  direct:    ${jb.slice(0, 300)}`); }
};
// PostgREST prints times as 2026-11-24T10:00:00+00:00; Postgres's json as the same.
const both = async (label: string, fn: string, args: Record<string, unknown>) =>
  same(label, await postgrest.rpc(fn, args).catch((e) => `error ${e.message}`), await direct.rpc(fn, args).catch((e) => `error ${e.message}`));

const someAccount = (await direct.rpc<any[]>("poll_routes", { p_seconds: Array.from({ length: 60 }, (_, i) => i) }))?.[0]?.account_id
  ?? "00000000-0000-4000-8000-000000000000";
await both("set of rows (poll_routes)", "poll_routes", { p_seconds: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] });
await both("set of rows, uuid[] and bigint[] arguments", "inverters_cached_many", { p_accounts: [someAccount], p_plants: null });
await both("set of scalars (live_plants)", "live_plants", {});
await both("scalar text, null answer (account_refresh_get)", "account_refresh_get", { p_account: someAccount });
await both("scalar jsonb (sunsynk_calls_report)", "sunsynk_calls_report", {});
await both("scalar uuid (share_retry_due)", "share_retry_due", {});
await both("jsonb argument, void answer (sunsynk_tally)", "sunsynk_tally", { p_rows: [{ kind: "pgdb_parity", result: "ok", calls: 1, ms: 1, ms_max: 1 }], p_shard: null, p_run_ms: 0, p_plants: 0 });
// errors: the wording differs, the `fn: ` start the callers read does not
const prefix = async (db: typeof direct | typeof postgrest, fn: string, args: Record<string, unknown>) =>
  await db.rpc(fn, args).then(() => "answered", (e) => String(e.message).split(": ")[0]);
same("unknown function: an error starting `fn: `", await prefix(postgrest, "no_such_function_x", {}), await prefix(direct, "no_such_function_x", {}));
same("wrong argument names: an error starting `fn: `", await prefix(postgrest, "poll_routes", { p_nope: 1 }), await prefix(direct, "poll_routes", { p_nope: 1 }));
same("configuredPlants", await postgrest.configuredPlants([1, 2, 5001]).catch((e) => e.message), await direct.configuredPlants([1, 2, 5001]).catch((e) => e.message));
const err = await direct.rpc("poll_commit_batch", { p_ts: 0, p_rows: [{ account: null }] }).catch((e) => e);
same("error: `fn: message` with the SQLSTATE", [String(err.message).startsWith("poll_commit_batch: "), typeof err.code], [true, "string"]);
await direct.rpc("sunsynk_tally", { p_rows: [], p_shard: null, p_run_ms: 0, p_plants: 0 });
await direct.end();
// the tally rows written above
const { db } = await import("../supabase/functions/_shared/db.ts");
await db.rpc("sunsynk_tally", { p_rows: [], p_shard: null, p_run_ms: 0, p_plants: 0 });
console.log(failed ? `${failed} failed` : "pgdb parity: all passed");
Deno.exit(failed ? 1 : 0);
