#!/usr/bin/env node
// SOLAR-641 state test, on today's schema (SOLAR-661). Runs scripts/sql/billing-state-tests.sql
// in one transaction on a local database at the newest migration (scripts/local-db.mjs), then
// rolls it back. Exit 0: every check passed. Exit 1: a check failed or the SQL broke.
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { REPO, psql } from './local-db.mjs';

// No edge function may name a column 0252 dropped (plant_users.paused) in a query.
const fnDir = path.join(REPO, 'supabase/functions');
const stale = readdirSync(fnDir, { recursive: true }).filter((f) => String(f).endsWith('.ts')).flatMap((f) =>
  readFileSync(path.join(fnDir, String(f)), 'utf8').split('\n').map((l, i) => [f, i + 1, l])
    .filter(([, , l]) => /\.(eq|neq|is|in|not|or|order|select|filter|match|update|upsert)\(\s*["'`][^"'`]*\bpaused\b/.test(l))
    .map(([f, n]) => `${f}:${n}`));
if (stale.length) {
  console.log(`FAIL  edge functions read plant_users.paused, which 0252 dropped: ${stale.join(', ')}`);
  process.exit(1);
}

const sql = ['begin;', readFileSync(path.join(REPO, 'scripts/sql/billing-state-tests.sql'), 'utf8'), 'rollback;'].join('\n');
const r = psql(sql);
const lines = (r.stderr || '').split('\n').filter((l) => /FAIL|checks,|ERROR|failed|CONTEXT|LINE|line /.test(l));
console.log(lines.join('\n') || (r.error ? String(r.error) : '(no output)'));
// psql's status, and the summary line: a file cut short before it would exit 0 with no checks
process.exit(r.status === 0 && /\d+ checks, 0 failed/.test(r.stderr) ? 0 : 1);
