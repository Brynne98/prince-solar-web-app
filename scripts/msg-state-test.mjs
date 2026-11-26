#!/usr/bin/env node
// SOLAR-665: the message outbox, alert and notify SQL tests; SOLAR-673 adds the inverter list,
// silent inverter and warning email ones; SOLAR-676 the day's peak; SOLAR-679 F13 blocked mail addresses. On a local database at the newest migration
// (scripts/local-db.mjs). Each file opens its own transaction and rolls it back;
// AUTOCOMMIT=off keeps an edit that drops the begin, or adds SQL after the rollback, from
// saving rows. Exit 0: every file ran to its "all N checks passed" line. Exit 1: any did not.
import path from 'node:path';
import { REPO, psql } from './local-db.mjs';

const FILES = ['msg-outbox-tests', 'msg-outbox-email-tests', 'msg-outbox-bulk-tests', 'alert-queue-tests', 'notify-lanes-tests',
  'inverters-cached-tests', 'silent-inverter-tests', 'warning-tests', 'day-peak-tests', 'mail-blocked-tests'];

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
