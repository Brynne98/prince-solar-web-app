#!/usr/bin/env node
// Files that mirror the database (SOLAR-679 F5, F6, F9), checked against a database built from
// every migration:
//   supabase/schemas/functions/<schema>/<name>.sql  one per function in billing, msg, private and
//     public: its whole body as Postgres prints it (pg_get_functiondef). Grants, tables,
//     partitions and cron stay in numbered migrations only (F8).
//   supabase/functions/_shared/database.types.ts    the public schema's types (supabase gen types).
//
//   node scripts/db-files.mjs          check: exit 0 when every file matches the database, 1 when not
//   node scripts/db-files.mjs --write  rewrite the files from the database
//   node scripts/db-files.mjs --live   check the functions (not the types) of the project
//                                      SUPABASE_PROJECT_REF names (else the linked one), read only,
//                                      through the Supabase CLI (scripts/release.mjs)
//
// The database is STATE_DB_URL, local, at the newest migration (scripts/local-db.mjs). A function
// change is a migration and its file together: write the migration (the whole function, never
// a text patch), apply it locally, then --write; or edit the file and copy it into the migration.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const write = process.argv.includes('--write');
const live = process.argv.includes('--live');
const SCHEMAS = ['billing', 'msg', 'plants', 'private', 'public'];
const DIR = path.join(REPO, 'supabase/schemas/functions');
const TYPES = path.join(REPO, 'supabase/functions/_shared/database.types.ts');
const problems = [];

// ---- functions ----
const q = `select coalesce(json_agg(json_build_object('schema', n.nspname, 'name', p.proname, 'def', pg_get_functiondef(p.oid))
                  order by n.nspname, p.proname), '[]') as fns
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in (${SCHEMAS.map((s) => `'${s}'`).join(', ')}) and p.prokind in ('f', 'p')
   and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')`;
let fns;
if (live) {
  const r = spawnSync('supabase', ['db', 'query', process.env.SUPABASE_PROJECT_REF ? `--remote=${process.env.SUPABASE_PROJECT_REF}` : '--remote', '--read-only', '--output-format', 'json', q],
    { cwd: REPO, encoding: 'utf8', maxBuffer: 1 << 28 });
  if (r.status !== 0) { console.error(`supabase db query failed: ${r.stderr.trim().split('\n').at(-1)}`); process.exit(1); }
  const v = JSON.parse(r.stdout).rows[0].fns;
  fns = typeof v === 'string' ? JSON.parse(v) : v;
} else {
  const { psql } = await import('./local-db.mjs');
  const r = psql(q, ['-At']);
  if (r.status !== 0) { console.error(r.stderr.trim()); process.exit(1); }
  fns = JSON.parse(r.stdout);
}
const want = new Map();
for (const f of fns) {
  const rel = `${f.schema}/${f.name}.sql`;
  // one file per name: a second function with the same name would need a second file
  if (want.has(rel)) problems.push(`${rel}: two functions with one name: give each its own name`);
  want.set(rel, f.def.trimEnd() + ';\n');
}
const have = new Map();
for (const s of fs.existsSync(DIR) ? fs.readdirSync(DIR).filter((d) => fs.statSync(path.join(DIR, d)).isDirectory()) : [])
  for (const f of fs.readdirSync(path.join(DIR, s)).filter((f) => f.endsWith('.sql')))
    have.set(`${s}/${f}`, fs.readFileSync(path.join(DIR, s, f), 'utf8'));

if (write) {
  fs.rmSync(DIR, { recursive: true, force: true });
  for (const [rel, body] of want) {
    fs.mkdirSync(path.dirname(path.join(DIR, rel)), { recursive: true });
    fs.writeFileSync(path.join(DIR, rel), body);
  }
} else {
  // --except <schema/name.sql>: a function a pending migration will change (scripts/release.mjs)
  const except = new Set(process.argv.flatMap((a, i, all) => all[i - 1] === '--except' ? [a] : []));
  for (const [rel, body] of want) {
    if (except.has(rel)) continue;
    if (!have.has(rel)) problems.push(`${rel}: the database has this function, no file does`);
    else if (have.get(rel) !== body) problems.push(`${rel}: the file differs from the database's body`);
  }
  for (const rel of have.keys()) if (!want.has(rel) && !except.has(rel)) problems.push(`${rel}: no such function in the database`);
}

if (live) {
  if (problems.length) { console.log(problems.map((p) => `FAIL  ${p}`).join('\n')); process.exit(1); }
  console.log(`live functions: ${want.size}, all the same as their files`);
  process.exit(0);
}

// ---- every table has an owner (SOLAR-681 R1) ----
{
  const { psql } = await import('./local-db.mjs');
  const r = psql(`select coalesce(json_agg(n.nspname || '.' || c.relname order by 1), '[]') from pg_class c
    join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r', 'p') and not c.relispartition
     and n.nspname in (${SCHEMAS.map((s) => `'${s}'`).join(', ')})`, ['-At']);
  if (r.status !== 0) { console.error(r.stderr.trim()); process.exit(1); }
  const dbt = new Set(JSON.parse(r.stdout));
  const owned = new Set(Object.keys(JSON.parse(fs.readFileSync(path.join(REPO, 'supabase/owners.json'), 'utf8')).tables));
  for (const t of dbt) if (!owned.has(t)) problems.push(`supabase/owners.json: table ${t} has no owner part`);
  for (const t of owned) if (!dbt.has(t)) problems.push(`supabase/owners.json: ${t} is not a table in the database`);
}

// ---- types ----
// supabase gen types reads the database by address; local-db.mjs has already refused anything
// that is not a local database at the newest migration.
const gen = spawnSync('supabase', ['gen', 'types', `--remote=${process.env.STATE_DB_URL}`, '--lang', 'typescript', '--schema', 'public'],
  { encoding: 'utf8', maxBuffer: 1 << 26 });
if (gen.status !== 0 || !gen.stdout.includes('export type Database')) {
  console.error(`supabase gen types failed: ${(gen.stderr || String(gen.error)).trim().split('\n').at(-1)}`);
  process.exit(1);
}
const types = '// Generated by `node scripts/db-files.mjs --write` (supabase gen types). Do not edit.\n' + gen.stdout;
if (write) fs.writeFileSync(TYPES, types);
else if (!fs.existsSync(TYPES) || fs.readFileSync(TYPES, 'utf8') !== types)
  problems.push('supabase/functions/_shared/database.types.ts: stale, the database\'s public schema has changed');

if (write) {
  console.log(`wrote ${want.size} function files and database.types.ts`);
  process.exit(problems.length ? 1 : 0);
}
if (problems.length) {
  console.log(problems.map((p) => `FAIL  ${p}`).join('\n'));
  console.log(`\n${problems.length} database file${problems.length === 1 ? '' : 's'} out of step with the migrations.`
    + ' Apply the migration locally, then: node scripts/db-files.mjs --write');
  process.exit(1);
}
console.log(`database files: ${want.size} functions, ${have.size} files, types current`);
