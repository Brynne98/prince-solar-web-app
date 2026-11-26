#!/usr/bin/env node
// SOLAR-681: logins and plants SQL tests (rules R1-R26 of reports/rework-step-2-logins-plants-reading.md). On a local database at the newest migration
// (scripts/local-db.mjs). Each file opens its own transaction and rolls it back;
// AUTOCOMMIT=off keeps an edit that drops the begin, or adds SQL after the rollback, from
// saving rows. Exit 0: every file ran to its "all N checks passed" line. Exit 1: any did not.
import path from 'node:path';
import { REPO, psql } from './local-db.mjs';

const FILES = ['plants-tests'];

let failed = 0;
for (const f of FILES) {
  const r = psql(undefined, ['-v', 'AUTOCOMMIT=off', '-f', path.join(REPO, 'scripts/sql', `${f}.sql`)]);
  const err = r.stderr || '';
  // the summary line as well as the status: a file cut short, or with no checks, exits 0 too
  const done = err.match(/all ([1-9]\d*) checks passed/);
  if (r.status === 0 && done) { console.log(`ok    ${f}: ${done[1]} checks`); continue; }
  failed++;
  console.log(`FAIL  ${f}`);
  console.log(r.error ? String(r.error) : err.split('\n').filter((l) => l && !/NOTICE:\s+ok\s/.test(l)).join('\n'));
}
process.exit(failed ? 1 : 0);
