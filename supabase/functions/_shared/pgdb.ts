// A direct-Postgres database handle (SOLAR-656, poller v3). The lanes give it to useDb() in
// place of PostgREST. One connection per handle (`max: 1`): through Supavisor's transaction
// pooler (port 6543) in production, so prepared statements are off.
//
// It answers as PostgREST does (see Db.rpc in db.ts): Postgres itself turns the answer into
// JSON (json_agg for a set-returning function, to_json for one value) and every argument
// goes in as JSON, cast to the parameter's declared type. The function's arguments, return
// and set-ness come from pg_proc, read once per function name.
import postgres from "npm:postgres@3.4.5";
import type { Db } from "./db.ts";

type Arg = { name: string; type: string; required: boolean };
type Proc = { set: boolean; void: boolean; args: Arg[] };

/** A database error with Postgres's SQLSTATE (40P01 = deadlock). Message: `fn: message`. */
export class DbError extends Error {
  constructor(message: string, public code?: string) {
    super(message);
  }
}

export type DirectDb = Db & {
  /** Close the connection. */
  end(): Promise<void>;
};

const ident = (s: string) => `"${s.replaceAll('"', '""')}"`;

// One JSON parameter, cast to the declared type: json/jsonb as is, an array from its
// elements, anything else from the JSON value's text.
function cast(p: string, type: string): string {
  if (type === "jsonb" || type === "json") return `${p}::${type}`;
  if (type.endsWith("[]")) return `array(select jsonb_array_elements_text(${p}))::${type}`;
  return `(${p} #>> '{}')::${type}`;
}

/** A handle on `url`. Each statement is cancelled after `timeoutMs`. */
export function directDb(url: string, { timeoutMs = 25_000 } = {}): DirectDb {
  const sql = postgres(url, { max: 1, prepare: false, idle_timeout: 30, connect_timeout: 10, onnotice: () => {} });
  const procs = new Map<string, Promise<Proc[]>>();

  async function run<T>(label: string, text: string, params: unknown[] = []): Promise<T> {
    const q = sql.unsafe(text, params as any[]);
    const timer = setTimeout(() => q.cancel(), timeoutMs);
    try {
      return await q as unknown as T;
    } catch (e: any) {
      throw new DbError(`${label}: ${e?.message ?? e}`, e?.code);
    } finally {
      clearTimeout(timer);
    }
  }

  // Every function of that name in public: its input arguments (IN, INOUT, VARIADIC) and
  // how many of them have defaults (the last ones).
  const procsOf = (fn: string) => {
    let p = procs.get(fn);
    if (!p) {
      p = run<any[]>(fn, `
        select p.proretset as set, p.prorettype = 'void'::regtype as void, p.pronargdefaults as defaults,
               coalesce(p.proargnames, '{}') as names, coalesce(p.proargmodes::text[], '{}') as modes,
               array(select format_type(t, null) from unnest(p.proargtypes) with ordinality u(t, n) order by n) as types
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = $1`, [fn]).then((rows) => rows.map((r) => {
        const names = (r.names as string[]).filter((_, i) => !r.modes.length || ["i", "b", "v"].includes(r.modes[i]));
        const types = r.types as string[];
        return {
          set: r.set, void: r.void,
          args: types.map((type, i) => ({ name: names[i] ?? "", type, required: i < types.length - Number(r.defaults) })),
        };
      }));
      p.catch(() => procs.delete(fn));
      procs.set(fn, p);
    }
    return p;
  };

  return {
    async rpc(fn, args) {
      const keys = Object.keys(args).filter((k) => args[k] !== undefined);
      const pick = (await procsOf(fn)).find((p) =>
        keys.every((k) => p.args.some((a) => a.name === k)) && p.args.every((a) => !a.required || keys.includes(a.name)));
      if (!pick) throw new DbError(`${fn}: no function public.${fn} takes (${keys.join(", ")})`);
      const params: string[] = [];
      const named = keys.map((k) => {
        const type = pick.args.find((a) => a.name === k)!.type;
        if (args[k] === null) return `${ident(k)} => null::${type}`;
        params.push(JSON.stringify(args[k]));
        return `${ident(k)} => ${cast(`$${params.length}::jsonb`, type)}`;
      }).join(", ");
      const call = `public.${ident(fn)}(${named})`;
      const text = pick.void ? `select ${call}, null::text as j`
        : pick.set ? `select coalesce(json_agg(r), '[]')::text as j from ${call} r`
        : `select to_json(${call})::text as j`;
      const rows = await run<{ j: string | null }[]>(fn, text, params);
      return rows[0]?.j == null ? null : JSON.parse(rows[0].j);
    },
    async configuredPlants(ids) {
      const rows = await run<{ plant_id: string }[]>("plant_config",
        `select plant_id::text from public.plant_config where plant_id = any(array(select jsonb_array_elements_text($1::jsonb))::bigint[])`,
        [JSON.stringify(ids)]);
      return rows.map((r) => Number(r.plant_id));
    },
    async clearBookmarks(ids) {
      await run("plant_config",
        `update public.plant_config set backfill_next = null, backfill_until = null, temp_next = null
          where plant_id = any(array(select jsonb_array_elements_text($1::jsonb))::bigint[])`, [JSON.stringify(ids)]);
    },
    end: () => sql.end({ timeout: 5 }),
  };
}
