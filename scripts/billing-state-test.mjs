#!/usr/bin/env node
// SOLAR-641 state test. LOCAL database only (STATE_DB_URL to change; default the local
// Supabase on 55322). Applies the billing migrations (0240 on, *_billing_*), runs
// scripts/sql/billing-state-tests.sql, then the drop of the old billing
// (0252_billing_drop_old) in one transaction, then rolls it all back, so the
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
// the drop of the old billing runs last, after the checks (it is a billing file too)
const DROP = '0252_billing_drop_old.sql';
const migrations = readdirSync(dir).filter((f) => /^\d{4}_billing_/.test(f) && Number(f.slice(0, 4)) >= 240 && f !== DROP).sort();
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
  readFileSync(path.join(dir, DROP), 'utf8'),
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

// DEPLOY.md step 6.1: the old wipe queue is emptied after the freeze, before the copy (verify 4
// fix 5); once switched its jobs stand down and its plants would stay forever
const deploy = readFileSync(path.join(REPO, 'DEPLOY.md'), 'utf8');
const step61 = deploy.slice(deploy.indexOf("pause_old('all')"), deploy.indexOf('2. Copy again'));
if (!step61.includes('call private.purge_plants()') || !step61.includes('select count(*) from private.plant_purge')) {
  console.log('FAIL  DEPLOY.md step 6.1 does not empty private.plant_purge before the copy');
  process.exit(1);
}
// ... and checked again after the copy and switch (verify 5 fix 4): a plant queued in between stays
const step62 = deploy.slice(deploy.indexOf('2. Copy again'), deploy.indexOf('3. `supabase functions deploy billing`'));
if (!step62.includes('select count(*) from private.plant_purge')) {
  console.log('FAIL  DEPLOY.md step 6.2 does not check private.plant_purge again after the switch');
  process.exit(1);
}

// The drop (0260) makes api_account_delete again: it keeps 0247's lock order before the account
// (billing-lock-test.mjs races 0247's; final review, Astra). Each lock, in order, before delete_account.
const delBody = (t) => { const i = t.indexOf('function public.api_account_delete()'); return t.slice(i, t.indexOf('end $$;', i)); };
const locks = ['pg_advisory_xact_lock_shared(3, 0)', 'union select account_id from public.plant_users',
  'pg_advisory_xact_lock(1, hashtext(acc.id::text))', 'where user_id = uid order by plant_id for update', 'billing.delete_account('];
for (const [name, body] of [['0247', delBody(texts.find((t) => t.includes('0247 —') || t.includes('api_account_delete_old')) ?? '')],
  ['0260', delBody(readFileSync(path.join(dir, DROP), 'utf8'))]]) {
  const at = locks.map((l) => body.indexOf(l));
  if (at.some((x) => x < 0) || at.some((x, i) => i && x < at[i - 1])) {
    console.log(`FAIL  ${name} api_account_delete does not take the writers' locks before the account (${locks.filter((l, i) => at[i] < 0).join('; ') || 'out of order'})`);
    process.exit(1);
  }
}

const r = spawnSync(PSQL, ['-X', '-q', '-v', 'ON_ERROR_STOP=1', DB], { input: sql, encoding: 'utf8' });
const lines = (r.stderr || '').split('\n').filter((l) => /FAIL|checks,|ERROR|failed|CONTEXT|LINE|line |old billing: ok|X3 after|api_offer/.test(l));
console.log(`migrations: ${migrations.join(' ')}`);
console.log(lines.join('\n') || (r.error ? String(r.error) : '(no output)'));
process.exit(r.status === 0 ? 0 : 1);
