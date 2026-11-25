#!/usr/bin/env node
// SOLAR-642 lock-order races. LOCAL database only, at the newest migration (STATE_DB_URL, local-db.mjs). Each race calls
// the real functions in two connections. A third connection (the gate) holds one lock for
// 2 s, so both writers are part-way in, each holding its first locks, when it lets go. With
// the locks taken in two orders Postgres finds a deadlock and cancels one; 0273 puts them in
// one order. Every race rolls back; the rows it races on are made first and removed at the end.
// Exit 0: no deadlock. Exit 1: a deadlock or a broken run.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { DB_ARGS, ENV, PSQL, psql } from './local-db.mjs';

const sql = (q) => psql(q, ['-At']);
const run = (q) => new Promise((done) => {
  const p = spawn(PSQL, ['-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', ...DB_ARGS], { env: ENV });
  let err = '';
  p.stderr.on('data', (d) => { err += d; });
  p.on('close', (code) => done({ code, err }));
  p.stdin.end(`set statement_timeout = '20s';\n${q}`);
});
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const must = (r, what) => { if (r.status !== 0) { console.error(`${what} failed:`, r.stderr); clean(); process.exit(1); } return r.stdout.trim(); };

// lo/hi: account ids in a known order (billing.run takes accounts in id order)
const lo = () => '0' + randomUUID().slice(1), hi = () => 'f' + randomUUID().slice(1);
const u1 = randomUUID(), u2 = randomUUID(), u3 = randomUUID(), u4 = randomUUID(), u5 = randomUUID();
const a1 = randomUUID(), a2 = randomUUID(), a3 = hi(), a4 = lo();
const l1 = randomUUID(), l2 = randomUUID();
// the one share login: the database's own, else one made here (u5's) and removed at the end
const found = sql(`select id from private.sunsynk_accounts where kind = 'share' order by id limit 1`).stdout.trim();
const share = found || randomUUID();
const name = `lock-${u1}`;                    // l1 and l2 are copies of one login
const P1 = 990160001, P2 = 990160002, P3 = 990160003, P4 = 990160004;
const users = [u1, u2, u3, u4, u5].map((x) => `'${x}'`).join(',');
const plants = [P1, P2, P3, P4].join(',');

must(sql(`begin;
  insert into billing.switch_over (switched_at) values (now()) on conflict do nothing;
  insert into auth.users (id, email, created_at) select x, 'lock-' || x || '@state.test', now() from unnest(array[${users}]::uuid[]) x;
  -- a1 and a2 in their free week, so their plants are read now
  insert into billing.accounts (id, user_id, market, created_at, trial_started_at, trial_ends_at) values
    ('${a1}', '${u1}', 'ZA', now(), now(), now() + interval '7 days'), ('${a2}', '${u2}', 'ZA', now(), now(), now() + interval '7 days'),
    ('${a3}', '${u3}', 'ZA', now(), null, null), ('${a4}', '${u4}', 'ZA', now(), null, null);
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values
    ('${l1}', '${u1}', '${name}', 'active', 'login'), ('${l2}', '${u2}', '${name}', 'active', 'login');
  ${found ? '' : `insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values ('${share}', '${u5}', 'lock-share-${u5}', 'active', 'share');`}
  insert into billing.plants (id, brand, external_id) select x, 'sunsynk', x::text from unnest(array[${plants}]) x;
  insert into billing.logins (id, account, brand, username, status) values
    ('${l1}', '${a1}', 'sunsynk', '${name}', 'ok'), ('${l2}', '${a2}', 'sunsynk', '${name}', 'ok');
  -- l1 reaches P2, its copy l2 reaches P1 and P2: a status change on both locks P2, then P1
  insert into billing.login_plants (login, plant, last_seen_at) values
    ('${l1}', ${P2}, now()), ('${l2}', ${P1}, now()), ('${l2}', ${P2}, now());
  insert into billing.seats (account, plant, chosen_at) values ('${a1}', ${P2}, now()), ('${a2}', ${P2}, now());
  insert into public.plant_users (plant_id, user_id, account_id, plant_name) values
    (${P2}, '${u1}', '${l1}', 'Lock'), (${P2}, '${u2}', '${l2}', 'Lock');
  -- two shares that ended an hour ago, P3 (the later account) first
  insert into public.plant_users (plant_id, user_id, account_id, plant_name, via_share, share_missing_at) values
    (${P3}, '${u3}', '${share}', 'Lock 3', true, now() - interval '2 hours');
  insert into public.plant_users (plant_id, user_id, account_id, plant_name, via_share, share_missing_at) values
    (${P4}, '${u4}', '${share}', 'Lock 4', true, now() - interval '2 hours');
  insert into billing.plant_claims (plant, account) values (${P3}, '${a3}'), (${P4}, '${a4}');
  insert into billing.subscriptions (account, plan, currency, interval, amount_minor, status, started_at, billing_day,
                                     period_start, period_end)
  select x, (select min(code) from billing.plans), 'ZAR', 'month', 0, 'active', now(), 1, now(), now() + interval '20 days'
    from unnest(array['${a3}', '${a4}']::uuid[]) x;
commit;
select public.account_refresh_set('${l1}', 'lock-refresh');`), 'setup');
if (must(sql(`select (billing.plant_state(${P2})->>'read_now')::boolean`), 'read_now') !== 't') {
  console.error('setup: P2 is not read now'); clean(); process.exit(1);
}
const version = must(sql(`select version from billing.plants where id = ${P2}`), 'version');

function clean() {
  sql(`delete from billing.subscriptions where account in ('${a3}', '${a4}');
       delete from billing.plant_claims where plant in (${plants});
       delete from public.plant_users where user_id in (${users});
       delete from billing.seats where account in ('${a1}', '${a2}');
       delete from billing.login_plants where login in ('${l1}', '${l2}');
       delete from billing.logins where id in ('${l1}', '${l2}');
       delete from billing.account_events where account in ('${a1}', '${a2}', '${a3}', '${a4}');
       delete from billing.plants where id in (${plants});
       delete from vault.secrets where id in (select refresh_secret_id from private.sunsynk_accounts where user_id in (${users}));
       delete from private.sunsynk_login_events where account_id in ('${l1}', '${l2}'${found ? '' : `, '${share}'`});
       delete from private.sunsynk_accounts where user_id in (${users});
       delete from billing.accounts where id in ('${a1}', '${a2}', '${a3}', '${a4}');
       delete from auth.users where id in (${users});`);
}

const as = (u) => `select set_config('request.jwt.claims', json_build_object('sub', '${u}', 'role', 'authenticated')::text, true);`;
const poll = (login) => `select public.poll_commit_v2('{"${P2}": ${version}}'::jsonb, '${login}', extract(epoch from date_trunc('minute', now()))::bigint,
  '[]', '[]', '[{"plant_id": ${P2}, "pv_w": 1}]', '[]', '[]', 'lock-access', 4102444800);`;
const reconnect = `select public.link_login_live('${u1}', '${name}', 'lock-access', 4102444800, 'lock-refresh', '[{"id": ${P2}}]');`;
const tx = (body) => `begin;\n${body}\nrollback;`;

// gate: what it holds for 2 s; first: starts at 0.3 s; second: at 0.8 s
const races = [
  { name: '1. reconnect vs account delete',
    gate: `select 1 from billing.accounts where id = '${a1}' for update;`,
    first: tx(`${as(u1)} select public.api_account_delete();`),
    second: tx(reconnect) },
  { name: '2. login and its copy marked broken vs plant list',
    gate: `select 1 from billing.plants where id = ${P1} for update;`,
    first: tx(`select billing.login_seen('${l1}', '[{"id": ${P1}}, {"id": ${P2}}]');`),
    second: tx(`select public.account_mark('${l1}', 'needs_relink', 'lock test');`) },
  { name: '3a. poll save vs unlink of another login on the plant',
    gate: `select 1 from billing.accounts where id = '${a2}' for update;`,
    first: tx(`${as(u2)} select public.api_link_remove('${l2}');`),
    second: tx(poll(l1)) },
  { name: '3b. poll save vs reconnect of the same login',
    gate: `select 1 from private.sunsynk_accounts where id = '${l1}' for no key update;`,  // the reconnect's event row still reads it
    first: tx(reconnect),
    second: tx(poll(l1)) },
  { name: '3c. two polls on a plant whose history was deleted',
    before: `update billing.plants set history_purged_at = now() where id = ${P2};`,
    after: `update billing.plants set history_purged_at = null where id = ${P2};`,
    gate: `select 1 from private.sunsynk_accounts where id in ('${l1}', '${l2}') for update;`,
    first: tx(poll(l1)),
    second: tx(poll(l2)) },
  { name: '4. two shares ending vs billing run',
    gate: `select pg_sleep(0);`,
    first: tx(`select billing.lock_account('${a4}'); select pg_sleep(1.5);
      do $$ begin if billing.run() ? 'busy' then raise exception 'billing.run is busy: nothing raced'; end if; end $$;`),
    second: tx(`select public.share_sync('${share}', '{}');`),
    secondAt: 300 },
];

let failed = 0;
const picked = races.filter((x) => !process.env.ONLY || x.name.startsWith(process.env.ONLY));
try {
  for (const r of picked) {
    if (r.before) must(sql(r.before), `${r.name}: before`);
    const g = run(tx(`${r.gate} select pg_sleep(2);`));
    await wait(300);
    const a = run(r.first);
    await wait(r.secondAt ?? 500);
    const b = run(r.second);
    if (process.env.PEEK) { await wait(700); console.log(sql(`select pid, left(query, 60), wait_event_type, wait_event from pg_stat_activity where datname = current_database() and state <> 'idle' and pid <> pg_backend_pid()`).stdout); }
    const out = await Promise.all([g, a, b]);
    if (r.after) must(sql(r.after), `${r.name}: after`);
    const err = out.map((x) => x.err).join('');
    const dead = /deadlock detected/.test(err);
    const broke = !dead && out.some((x) => x.code !== 0);
    if (dead || broke) failed++;
    console.log(`${dead || broke ? 'FAIL' : 'ok  '}  ${r.name}${dead ? ': deadlock' : broke ? ': ' + err.split('\n').find((l) => /ERROR/.test(l)) : ''}`);
  }
} finally {
  clean();
}
console.log(`${picked.length} lock-order races, ${failed} failed`);
process.exit(failed ? 1 : 0);
