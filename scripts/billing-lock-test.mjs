#!/usr/bin/env node
// SOLAR-641 lock-order test (final re-score, Sol). LOCAL database only. Two connections race an
// account delete against the writers that take their locks in another order: the
// poller's share update (a link row, then the account), the poller marking a login (its row,
// then its plants), a reconnect (the login's lock, then
// the account) and a claim of a plant whose share lapsed (the share login's lock, the plant,
// then the lapsed link row). The delete must take the same order, or Postgres finds a deadlock
// and cancels one of them. Each race runs in transactions that roll back; the account it races on is made
// first and removed at the end. Exit 0: no deadlock. Exit 1: a deadlock or a broken run.
//
// Each race is a handshake, no fixed sleep (SOLAR-664): the writer runs its first step and
// says so, holding its transaction open; the delete starts and says its pid; a third
// connection waits until pg_blocking_pids shows the delete blocked on the writer; only then
// does the writer take its second lock. A race that never overlaps fails. Every wait is bounded.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { DB_ARGS, ENV, PSQL, psql } from './local-db.mjs';

const sql = (q) => psql(q, ['-At']);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
// bounds: each wait in Node, and the database's own. lock_timeout stays well above
// deadlock_timeout (1 s by default), so a real deadlock is still reported as one.
const STEP_MS = 5000, RACE_MS = 30000;
const LIMITS = `set statement_timeout = '15s'; set lock_timeout = '10s'; set idle_in_transaction_session_timeout = '20s';`;

// a psql that reads its SQL as we send it; stdout is read line by line
function session() {
  const p = spawn(PSQL, ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', ...DB_ARGS], { env: ENV });
  const s = { p, out: '', err: '', code: null, send: (q) => p.stdin.write(q + '\n'), end: (q) => p.stdin.end(q + '\n') };
  p.stdout.on('data', (d) => { s.out += d; });
  p.stderr.on('data', (d) => { s.err += d; });
  p.stdin.on('error', () => {});      // it exited early; its exit code says why
  s.done = new Promise((r) => { p.on('close', (code) => { s.code = code; r(s); }); p.on('error', (e) => { s.err += e; s.code = -1; r(s); }); });
  s.stop = () => { if (s.code === null) p.kill('SIGKILL'); return s.done; };
  return s;
}
// the number after `${key}=` on a line of its own, within STEP_MS; fails at once if the session ends
async function said(s, key) {
  const re = new RegExp(`^${key}=(\\d+)$`, 'm');
  for (const end = Date.now() + STEP_MS; Date.now() < end; await wait(20)) {
    const m = s.out.match(re);
    if (m) return m[1];
    if (s.code !== null) throw new Error(`${key}: the session ended first: ${s.err.trim().split('\n')[0] || 'no error'}`);
  }
  throw new Error(`${key}: not said within ${STEP_MS} ms`);
}

const u = randomUUID(), login = randomUUID(), acc = randomUUID();
// the plant gets our own id from plants.plant_for (SOLAR-681), under a vendor id only this run uses
const tag = `lock-${u}`;
const made0 = sql(`select plants.plant_for('sunsynk', '${tag}')`);
if (made0.status !== 0) { console.error('setup failed:', made0.stderr); process.exit(1); }
const plant = Number(made0.stdout.trim());
// the one share login: the database's own, else one made here (owner) and removed at the end
const look = sql(`select id from plants.logins where kind = 'share'`);
if (look.status !== 0) { console.error('setup failed:', look.stderr); process.exit(1); }
const found = look.stdout.trim();
const owner = found ? null : randomUUID(), share = found || randomUUID();
const made = sql(`begin;
  insert into auth.users (id, email, created_at) values ('${u}', 'lock-${u}@state.test', now());
  ${owner ? `insert into auth.users (id, email, created_at) values ('${owner}', 'lock-share-${owner}@state.test', now());
  insert into plants.logins (id, user_id, brand, username, status, kind) values ('${share}', '${owner}', 'sunsynk', 'lock-share-${owner}', 'ok', 'share');` : ''}
  insert into billing.accounts (id, user_id, market, created_at) values ('${acc}', '${u}', 'ZA', now());
  insert into plants.logins (id, account, user_id, brand, username, status, kind) values ('${login}', '${acc}', '${u}', 'sunsynk', 'lock-${u}', 'ok', 'login');
  -- a share that dropped off the share login's list over an hour ago: its claim, its list row and its seat
  insert into plants.claims (plant, account, plant_name) values (${plant}, '${acc}', 'Lock');
  insert into plants.login_plants (login, plant, plant_name, last_seen_at, missing_since)
  values ('${share}', ${plant}, 'Lock', now() - interval '3 hours', now() - interval '2 hours');
  insert into billing.seats (account, plant, chosen_at) values ('${acc}', ${plant}, now());
commit;`);
if (made.status !== 0) { console.error('setup failed:', made.stderr); process.exit(1); }

// the delete as the user (rolled back); it must really delete, not refuse
const del = `${LIMITS} begin;
  select set_config('request.jwt.claims', json_build_object('sub', '${u}', 'role', 'authenticated')::text, true) is null;
  select 'pid=' || pg_backend_pid();
  select 'deleted=' || (public.api_account_delete()->>'deleted');
rollback;`;
// each writer: [its first lock, what it does after]; the handshake sits between the two
const races = {
  // plants.list_seen's order on the share login: its lock, then (the share gone over an hour: the claim
  // released) the owner's account
  'share update vs account delete': [
    `select pg_advisory_xact_lock(1, hashtext('${share}'));`,
    `select plants.list_seen('${share}', '[]'::jsonb);`],
  // a claim of the plant (plants.claim): the share login's lock, the account, then the plant
  'claim of a lapsed share vs account delete': [
    `select pg_advisory_xact_lock(1, hashtext('${share}'));`,
    `select billing.lock_account('${acc}');
     select billing.lock_plants(array[${plant}]::bigint[]);`],
  // the poller marking the login (account_mark): its row, then, through the status trigger
  // (plants.login_status_changed), the login's plants
  'login marked by the poller vs account delete': [
    `select public.account_mark('${login}', 'ok', null);`,
    `select billing.lock_plants(array[${plant}]::bigint[]);`],
  // a reconnect's order: the login's lock, then the account
  'reconnect vs account delete': [
    `select pg_advisory_xact_lock(1, hashtext('${login}'));`,
    `select billing.lock_account('${acc}');`],
};

// one race; throws when it could not be made to overlap, returns the two sessions otherwise
async function race([first, second]) {
  const w = session();
  let d = null;
  try {
    w.send(`${LIMITS} begin;\n${first}\nselect 'ready=' || pg_backend_pid();`);
    const wPid = await said(w, 'ready');                 // the writer holds its first lock
    d = session();
    d.end(del);
    const dPid = await said(d, 'pid');
    for (const end = Date.now() + STEP_MS; ; await wait(25)) {
      const r = sql(`select ${wPid} = any(pg_blocking_pids(${dPid}))`);
      if (r.status !== 0) throw new Error(`cannot read the locks: ${r.stderr.trim()}`);
      if (r.stdout.trim() === 't') break;                // the delete waits on the writer
      if (d.code !== null) throw new Error(`the delete ended without waiting on the writer${d.err.trim() ? ': ' + d.err.trim().split('\n')[0] : ''}`);
      if (Date.now() > end) throw new Error(`the delete never blocked on the writer within ${STEP_MS} ms`);
    }
    w.end(`${second}\nrollback;`);
    let timer;
    const late = new Promise((r) => { timer = setTimeout(() => r('late'), RACE_MS); });
    const over = await Promise.race([Promise.all([w.done, d.done]), late]);
    clearTimeout(timer);
    if (over === 'late') throw new Error(`the race did not finish within ${RACE_MS} ms`);
    return [w, d];
  } finally {
    await Promise.all([w.stop(), d?.stop()]);            // no session outlives its race
  }
}

let failed = 0, cleanFailed = false;
try {
  for (const [name, writer] of Object.entries(races)) {
    let why = '';
    try {
      const [a, b] = await race(writer);
      if (/deadlock detected/.test(a.err + b.err)) why = 'deadlock';
      else if (a.code !== 0 || b.code !== 0) why = (a.err + b.err).trim().split('\n')[0];
      else if (!/^deleted=true$/m.test(b.out)) why = `the delete did not delete: ${b.out.trim()}`;
    } catch (e) {
      why = /deadlock detected/.test(e.message) ? 'deadlock' : e.message;
    }
    if (why) failed++;
    console.log(`${why ? 'FAIL' : 'ok  '}  ${name}${why ? ': ' + why : ''}`);
  }
} finally {
  const clean = sql(`begin;
    delete from plants.claims where plant = ${plant}; delete from plants.login_plants where plant = ${plant};
    delete from billing.seats where account = '${acc}';
    delete from plants.plants where id = ${plant} and vendor_id = '${tag}';
    delete from plants.logins where user_id in ('${u}', '${owner ?? u}');
    delete from billing.accounts where id = '${acc}'; delete from auth.users where id in ('${u}', '${owner ?? u}');
  commit;`);
  if (clean.status !== 0) {
    cleanFailed = true;
    console.log(`FAIL  cleanup: ${clean.stderr.trim().split('\n')[0]} (user ${u}, plant ${plant})`);
  }
}
console.log(`${Object.keys(races).length} lock-order races, ${failed} failed${cleanFailed ? ', cleanup failed' : ''}`);
process.exit(failed || cleanFailed ? 1 : 0);
