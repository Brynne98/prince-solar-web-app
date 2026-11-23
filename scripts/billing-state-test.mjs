#!/usr/bin/env node
// SOLAR-641 state test. LOCAL database only (STATE_DB_URL to change; default the local
// Supabase on 55322). Applies the billing migrations (0240 on, *_billing_*), runs
// scripts/sql/billing-state-tests.sql, then the drop of the old billing
// (supabase/after-switch-over) in one transaction, then rolls it all back, so the
// local database is left as it was. Exit 0: every check passed. Exit 1: a check failed
// or the SQL broke.
import { spawnSync } from 'node:child_process';
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DB = process.env.STATE_DB_URL || 'postgresql://postgres:postgres@127.0.0.1:55322/postgres';
if (!/@(127\.0\.0\.1|localhost)[:/]/.test(DB)) {
  console.error('refusing to run: not the local database');
  process.exit(1);
}
const PSQL = process.env.PSQL || ['/opt/homebrew/opt/libpq/bin/psql', '/usr/local/opt/libpq/bin/psql'].find(existsSync) || 'psql';

const dir = path.join(REPO, 'supabase/migrations');
const migrations = readdirSync(dir).filter((f) => /^\d{4}_billing_/.test(f) && Number(f.slice(0, 4)) >= 240).sort();
// public functions the billing files create (not "create or replace"): dropped first, so a
// local database that already has the billing schema (the local preview) can run the test
// (not the ones a file renames first and makes again: those exist before the billing files)
const texts = migrations.map((f) => readFileSync(path.join(dir, f), 'utf8'));
const renamed = new Set(texts.flatMap((t) => [...t.matchAll(/^alter function (?:public|private)\.(\w+)\(.*rename/gm)].map((m) => m[1])));
const made = [...new Set(texts.flatMap((t) => [...t.matchAll(/^create function (public|private)\.(\w+)\(/gm)].map((m) => m[1] + '.' + m[2])))]
  .filter((n) => !renamed.has(n.split('.')[1]));
const dropMade = made.length ? `do $d$ declare f record; begin for f in select p.oid::regprocedure s from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace where n.nspname || '.' || p.proname = any (array['${made.join("','")}'])
  loop execute 'drop function ' || f.s || ' cascade'; end loop; end $d$;` : '';
// a function a file renames to *_old and makes again: on a database that already ran the file,
// the new one goes and the old one gets its name back first
const undoRenames = texts.flatMap((t) => [...t.matchAll(/^alter function (\w+)\.(\w+)\(([^)]*)\) rename to (\w+);/gm)])
  .map(([, sch, name, args, to]) => `do $r$ begin if to_regprocedure('${sch}.${to}(${args})') is not null then
    execute 'drop function if exists ${sch}.${name}(${args}) cascade'; execute 'alter function ${sch}.${to}(${args}) rename to ${name}';
    end if; end $r$;`).join('\n');
const sql = [
  'begin;',
  undoRenames,
  'drop schema if exists billing cascade;',
  dropMade,
  ...migrations.map((f) => readFileSync(path.join(dir, f), 'utf8')),
  readFileSync(path.join(REPO, 'scripts/sql/billing-state-tests.sql'), 'utf8'),
  // then the drop of the old billing (DEPLOY.md step 8) on top of it: it must run clean
  readFileSync(path.join(REPO, 'supabase/after-switch-over/0260_billing_drop_old.sql'), 'utf8'),
  "do $d$ begin raise notice 'drop of the old billing: ok'; end $d$;",
  // verify 3 fix 3 after the drop: no report on a plant the account no longer reaches
  "do $d$ declare e text := pg_temp.x3('-after-drop'); begin if e is not null then raise exception 'FAIL  X3 after the drop: %', e; end if; raise notice 'X3 after the drop: ok'; end $d$;",
  // the website's prices survive the drop, read from the billing tables (final fix 13)
  `do $d$ declare o jsonb; begin
     update billing.offers set max_members = null where code = 'launch';
     o := public.api_offer();
     if not has_function_privilege('anon', 'public.api_offer()', 'execute')
        or o->'offer'->>'id' is distinct from 'launch'
        or (o->'prices'->'monthly'->>'home')::numeric <> 49 or (o->'listPrices'->'monthly'->>'home')::numeric <> 99
        or (o->'prices'->'yearly'->>'family')::numeric <> 990 or (o->'listPrices'->'yearly'->>'family')::numeric <> 1990 then
       raise exception 'FAIL  api_offer after the drop: %', o;
     end if;
     raise notice 'api_offer after the drop: ok';
   end $d$;`,
  'rollback;',
].join('\n');

// No edge function may name a column the drop removes (plant_users.paused) in a query: linking
// and emails would break the moment 0260 runs. Before the switch they read 0247's
// chosen_plant_ids, which keeps the old rule inside the database.
const fnDir = path.join(REPO, 'supabase/functions');
const stale = readdirSync(fnDir, { recursive: true }).filter((f) => String(f).endsWith('.ts')).flatMap((f) =>
  readFileSync(path.join(fnDir, String(f)), 'utf8').split('\n').map((l, i) => [f, i + 1, l])
    .filter(([, , l]) => /\.(eq|neq|is|in|not|or|order|select|filter|match|update|upsert)\(\s*["'`][^"'`]*\bpaused\b/.test(l))
    .map(([f, n]) => `${f}:${n}`));
if (stale.length) {
  console.log(`FAIL  edge functions read plant_users.paused, which 0260 drops: ${stale.join(', ')}`);
  process.exit(1);
}

const r = spawnSync(PSQL, ['-X', '-q', '-v', 'ON_ERROR_STOP=1', DB], { input: sql, encoding: 'utf8' });
const lines = (r.stderr || '').split('\n').filter((l) => /FAIL|checks,|ERROR|failed|CONTEXT|LINE|line |old billing: ok|X3 after|api_offer/.test(l));
console.log(`migrations: ${migrations.join(' ')}`);
console.log(lines.join('\n') || (r.error ? String(r.error) : '(no output)'));
process.exit(r.status === 0 ? 0 : 1);
