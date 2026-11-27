#!/usr/bin/env node
// SOLAR-686 H21: imports never hold up the reader. LOCAL database only, at the newest migration
// (STATE_DB_URL, local-db.mjs). One plant read through one login, with a History import step
// claimed on it:
//   1. a reader save (poll_commit_v2) and an import write (history.bank_minutes) on that plant,
//      side by side, 100 times: no deadlock, no save waits over 1 s
//   2. an import write that meets a lock held for 3 s gives up after 1 s (lock_timeout), and its
//      step is retried
//   3. a day ending while its account switches the plant out, 50 times: no deadlock
// The rows it makes are removed at the end. Exit 0: all held. Exit 1: one did not.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { DB_ARGS, ENV, PSQL, psql } from './local-db.mjs';

const sql = (q) => psql(q, ['-At']);
const run = (q) => new Promise((done) => {
  const t0 = Date.now();
  const p = spawn(PSQL, ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', ...DB_ARGS], { env: ENV });
  let err = '', out = '';
  p.stdout.on('data', (d) => { out += d; });
  p.stderr.on('data', (d) => { err += d; });
  p.on('close', (code) => done({ code, err, out, ms: Date.now() - t0 }));
  p.stdin.end(q);
});
const must = (r, what) => { if (r.status !== 0) { console.error(`${what} failed:`, r.stderr); clean(); process.exit(1); } return r.stdout.trim(); };

const u = randomUUID(), a = randomUUID(), l = randomUUID();
const P = Number(must(sql(`select plants.plant_for('sunsynk', 'race-${u}')`), 'plant'));
const clean = () => sql(`begin;
  select set_config('billing.guarded', 'on', true);
  delete from public.agg_minute where plant_id = ${P};
  delete from history.days where plant = ${P}; delete from history.imports where plant = ${P}; delete from history.totals where plant = ${P};
  delete from billing.seats where account = '${a}';
  delete from plants.login_plants where login = '${l}'; delete from plants.logins where id = '${l}';
  delete from billing.account_events where account = '${a}'; delete from billing.accounts where id = '${a}';
  delete from auth.users where id = '${u}';
  delete from plants.plants where id = ${P};
  commit;`);

must(sql(`begin;
  insert into billing.switch_over (switched_at) values (now()) on conflict do nothing;
  insert into auth.users (id, email, created_at) values ('${u}', 'race-${u}@state.test', now());
  insert into billing.accounts (id, user_id, market, created_at, trial_started_at, trial_ends_at)
  values ('${a}', '${u}', 'ZA', now(), now(), now() + interval '7 days');
  insert into plants.logins (id, account, user_id, brand, username, status, kind) values ('${l}', '${a}', '${u}', 'sunsynk', 'race-${u}', 'ok', 'login');
  insert into plants.login_plants (login, plant, plant_name, last_seen_at) values ('${l}', ${P}, 'Race', now());
  insert into billing.seats (account, plant, chosen_at) values ('${a}', ${P}, now());
  select history.start(${P}, '${a}', 'switch');
  delete from history.totals where plant = ${P};
  commit;`), 'setup');
const step = JSON.parse(must(sql(`select history.take(0, 1)::text`), 'take')).find((s) => s.plant === P);
if (!step) { console.error('no step handed out'); clean(); process.exit(1); }
const v = Number(must(sql(`select version from plants.plants where id = ${P}`), 'version'));
const dayStart = Number(must(sql(`select public.day_start_epoch_tz('${step.day}'::date, plants.tz(${P}))`), 'day'));
const now = Math.floor(Date.now() / 60000) * 60;

let failed = 0;
const check = (ok, what) => { console.log(`${ok ? 'ok  ' : 'FAIL'}  ${what}`); if (!ok) failed++; };

// 1. side by side, 100 times
const saves = [], deadlocks = [];
for (let i = 0; i < 100; i++) {
  const ts = now - 3600 * 24 * 2 + i * 60;
  const save = `select public.poll_commit_v2('{"${P}": ${v}}'::jsonb, '${l}', ${ts}, '[]', '[]',
      '[{"plant_id": ${P}, "pv_w": 5}]'::jsonb, '[]', '[]', null, null);`;
  const rows = JSON.stringify(Array.from({ length: 60 }, (_, k) => ({ ts: dayStart + (i * 60 + k) * 60, pv_w: 1, grid_w: 1, load_w: 1 })));
  const imp = `select history.bank_minutes(${step.id}, '${step.claim}', '${rows}'::jsonb, 'invhistory');`;
  if (i % 30 === 0) sql(`select history.renew('day', ${step.id}, '${step.claim}')`);
  const [s, h] = await Promise.all([run(save), run(imp)]);
  saves.push(s.ms);
  for (const r of [s, h]) {
    if (/deadlock/i.test(r.err)) deadlocks.push(r.err.trim());
    else if (r.code !== 0) { check(false, `a write failed: ${r.err.trim()}`); break; }
  }
}
saves.sort((x, y) => x - y);
check(deadlocks.length === 0, `100 races, ${deadlocks.length} deadlocks`);
check(saves.at(-1) < 1000, `slowest reader save ${saves.at(-1)} ms (p50 ${saves[50]} ms), under 1 s`);

// 2. a lock held 3 s: the import write gives up after 1 s
const gate = run(`begin; select 1 from plants.plants where id = ${P} for update; select pg_sleep(3); rollback;`);
await new Promise((r) => setTimeout(r, 300));
const blocked = await run(`select history.bank_minutes(${step.id}, '${step.claim}', '[]'::jsonb, 'invhistory');`);
await gate;
check(blocked.code !== 0 && /lock timeout/i.test(blocked.err) && blocked.ms < 2000,
  `an import write under a held lock gives up in ${blocked.ms} ms: ${blocked.err.trim().split('\n')[0]}`);
const r = JSON.parse(must(sql(`select history.step_done('day', ${step.id}, '${step.claim}', 'failed', 'lock timeout')::text`), 'done'));
check(r.status === 'queued' && must(sql(`select tries from history.days where id = ${step.id}`), 'tries') === '1',
  'its step is retried (try 1, a minute later)');

// 3. a day ending while its account switches the plant out (step_done: import, then day; leave:
//    import, then days), 50 times
let dl3 = 0, bad3 = '';
for (let i = 0; i < 50; i++) {
  must(sql(`begin; update history.imports set status = 'stopped' where plant = ${P} and status = 'open';
    update history.days set status = 'dropped', closed_at = now() where plant = ${P} and status = 'queued';
    delete from history.totals where plant = ${P};
    select history.start(${P}, '${a}', 'switch'); delete from history.totals where plant = ${P}; commit;`), 'restart');
  const s3 = JSON.parse(must(sql(`select history.take(0, 1)::text`), 'take')).find((x) => x.plant === P);
  if (!s3) { bad3 = 'no step'; break; }
  const [d, l] = await Promise.all([
    run(`select history.step_done('day', ${s3.id}, '${s3.claim}', 'ok');`),
    run(`select history.leave(${P}, '${a}');`)]);
  for (const r of [d, l]) {
    if (/deadlock/i.test(r.err)) dl3++;
    else if (r.code !== 0) bad3 = r.err.trim();
  }
}
check(dl3 === 0 && !bad3, `a day ending beside a switch-out, 50 times: ${dl3} deadlocks${bad3 ? `, ${bad3}` : ''}`);

clean();
process.exit(failed ? 1 : 0);
