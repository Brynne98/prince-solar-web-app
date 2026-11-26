#!/usr/bin/env node
// SOLAR-659 background delete test. Runs scripts/sql/history-delete-run-tests.sql on a local
// database at the newest migration (scripts/local-db.mjs). Not in one transaction: the run
// commits. Its rows are for plants 990659xxx and are removed at the end.
// Exit 0: every check passed. Exit 1: a check failed or the SQL broke.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { REPO, psql } from './local-db.mjs';

const r = psql(readFileSync(path.join(REPO, 'scripts/sql/history-delete-run-tests.sql'), 'utf8'));
const lines = (r.stderr || '').split('\n').filter((l) => /ok |FAIL|checks,|ERROR|CONTEXT|LINE/.test(l))
  .map((l) => l.replace(/^psql:[^:]+:\d+: WARNING:\s*/, ''));
console.log(lines.join('\n') || (r.error ? String(r.error) : '(no output)'));
process.exit(r.status === 0 && /\d+ checks, 0 failed/.test(r.stderr) ? 0 : 1);
