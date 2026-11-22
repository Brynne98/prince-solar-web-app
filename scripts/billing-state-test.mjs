#!/usr/bin/env node
// SOLAR-641 state test. LOCAL database only (STATE_DB_URL to change; default the local
// Supabase on 55322). Applies the billing migrations (0240 on, *_billing_*) and runs
// scripts/sql/billing-state-tests.sql in one transaction, then rolls it all back, so the
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
const sql = [
  'begin;',
  'drop schema if exists billing cascade;',
  ...migrations.map((f) => readFileSync(path.join(dir, f), 'utf8')),
  readFileSync(path.join(REPO, 'scripts/sql/billing-state-tests.sql'), 'utf8'),
  'rollback;',
].join('\n');

const r = spawnSync(PSQL, ['-X', '-q', '-v', 'ON_ERROR_STOP=1', DB], { input: sql, encoding: 'utf8' });
const lines = (r.stderr || '').split('\n').filter((l) => /FAIL|checks,|ERROR|failed/.test(l));
console.log(`migrations: ${migrations.join(' ')}`);
console.log(lines.join('\n') || (r.error ? String(r.error) : '(no output)'));
process.exit(r.status === 0 ? 0 : 1);
