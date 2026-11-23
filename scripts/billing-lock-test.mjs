#!/usr/bin/env node
// SOLAR-641 lock-order test (final re-score, Sol). LOCAL database only. Two connections race an
// account delete against the writers that take their locks in another order: the
// poller's share update (a link row, then the account), a reconnect (the login's lock, then
// the account) and a claim of a plant whose share lapsed (the share login's lock, the plant,
// then the lapsed link row). The delete must take the same order, or Postgres finds a deadlock
// and cancels one of them. Each race runs in transactions that roll back; the account it races on is made
// first and removed at the end. Exit 0: no deadlock. Exit 1: a deadlock or a broken run.
import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

const DB = process.env.STATE_DB_URL || 'postgresql://postgres:postgres@127.0.0.1:55322/postgres';
if (!/@(127\.0\.0\.1|localhost)[:/]/.test(DB)) { console.error('refusing to run: not the local database'); process.exit(1); }
const PSQL = process.env.PSQL || ['/opt/homebrew/opt/libpq/bin/psql', '/usr/local/opt/libpq/bin/psql'].find(existsSync) || 'psql';
const sql = (q) => spawnSync(PSQL, ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', DB], { input: q, encoding: 'utf8' });
const run = (q) => new Promise((done) => {
  const p = spawn(PSQL, ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', DB]);
  let err = '';
  p.stderr.on('data', (d) => { err += d; });
  p.on('close', (code) => done({ code, err }));
  p.stdin.end(q);
});
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const u = randomUUID(), login = randomUUID(), acc = randomUUID(), plant = 990150001;
// the one share login: the database's own, else one made here (owner) and removed at the end
const found = sql(`select id from private.sunsynk_accounts where kind = 'share'`).stdout.trim();
const owner = found ? null : randomUUID(), share = found || randomUUID();
const made = sql(`begin;
  insert into auth.users (id, email, created_at) values ('${u}', 'lock-${u}@state.test', now());
  ${owner ? `insert into auth.users (id, email, created_at) values ('${owner}', 'lock-share-${owner}@state.test', now());
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values ('${share}', '${owner}', 'lock-share-${owner}', 'active', 'share');` : ''}
  insert into billing.accounts (id, user_id, market, created_at) values ('${acc}', '${u}', 'ZA', now());
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values ('${login}', '${u}', 'lock-${u}', 'active', 'login');
  -- a share that lapsed: its link row and seat stay, through the share login
  insert into public.plant_users (plant_id, user_id, account_id, plant_name, via_share, share_gone_at)
  values (${plant}, '${u}', '${share}', 'Lock', true, now());
  insert into billing.plants (id, brand, external_id) values (${plant}, 'sunsynk', '${plant}') on conflict do nothing;
  insert into billing.seats (account, plant, chosen_at) values ('${acc}', ${plant}, now());
commit;`);
if (made.status !== 0) { console.error('setup failed:', made.stderr); process.exit(1); }

// the delete as the user, once the switch is on (only inside its own transaction)
const del = `begin;
  insert into billing.switch_over (switched_at) values (now()) on conflict do nothing;
  select set_config('request.jwt.claims', json_build_object('sub', '${u}', 'role', 'authenticated')::text, true);
  select public.api_account_delete();
rollback;`;
const races = {
  // share_sync's order: the link row, then the account
  'share update vs account delete': `begin;
    update public.plant_users set share_missing_at = now() where user_id = '${u}';
    select pg_sleep(1.5);
    select billing.lock_account('${acc}');
  rollback;`,
  // a claim of the lapsed plant (share_claim_live): the share login's lock, the plant, then
  // the lapsed link row goes
  'claim of a lapsed share vs account delete': `begin;
    select pg_advisory_xact_lock(1, hashtext('${share}'));
    select billing.lock_plants(array[${plant}]::bigint[]);
    select pg_sleep(1.5);
    delete from public.plant_users where plant_id = ${plant} and user_id = '${u}' and share_gone_at is not null;
  rollback;`,
  // a reconnect's order: the login's lock, then the account
  'reconnect vs account delete': `begin;
    select pg_advisory_xact_lock(1, hashtext('${login}'));
    select pg_sleep(1.5);
    select billing.lock_account('${acc}');
  rollback;`,
};

let failed = 0;
try {
  for (const [name, writer] of Object.entries(races)) {
    const w = run(writer);
    await wait(500);                  // the writer holds its first lock; the delete starts
    const [a, b] = await Promise.all([w, run(del)]);
    const dead = /deadlock detected/.test(a.err + b.err);
    const broke = !dead && (a.code !== 0 || b.code !== 0);
    if (dead || broke) failed++;
    console.log(`${dead ? 'FAIL' : broke ? 'FAIL' : 'ok  '}  ${name}${dead ? ': deadlock' : broke ? ': ' + (a.err + b.err).split('\n')[0] : ''}`);
  }
} finally {
  sql(`delete from public.plant_users where user_id = '${u}'; delete from billing.seats where account = '${acc}';
       delete from billing.plants where id = ${plant}; delete from private.sunsynk_accounts where user_id in ('${u}', '${owner ?? u}');
       delete from billing.accounts where id = '${acc}'; delete from auth.users where id in ('${u}', '${owner ?? u}');`);
}
console.log(`${Object.keys(races).length} lock-order races, ${failed} failed`);
process.exit(failed ? 1 : 0);
