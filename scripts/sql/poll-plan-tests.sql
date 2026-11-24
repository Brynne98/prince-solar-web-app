-- SOLAR-650 Part B (0253): the poll minute plan. LOCAL database only; everything is rolled back.
--   /opt/homebrew/opt/libpq/bin/psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" -f scripts/sql/poll-plan-tests.sql
-- Exit code decides: any wrong case raises. The scale part prints its timings as notices.
\set QUIET on
\set ON_ERROR_STOP on
\o /dev/null
begin;

create function pg_temp.eq(label text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  if got is distinct from want then raise exception 'FAIL %: got %, want %', label, got, want; end if;
  raise notice 'PASS  %', label;
end $$;
create function pg_temp.ok(label text, got boolean) returns void language plpgsql as $$
begin
  if got is not true then raise exception 'FAIL %', label; end if;
  raise notice 'PASS  %', label;
end $$;

-- Plants poll_jobs_v2 reads that the minute's plan reads through another login, or not at all.
create function pg_temp.diff(m timestamptz) returns bigint language sql as $$
  select count(*) from (select plant, lane from private.poll_plan where minute = m) pp
    full join (select plant_id, account_id from public.poll_jobs_v2(0, 1)) j on j.plant_id = pp.plant
   where pp.lane is distinct from j.account_id
$$;

-- n accounts in their free week, each with one login of `per` plants; plant ids from `base`.
-- Inverters per plant: 1 + (plant % inv_mod), or 0 for every 7th plant (not listed yet).
create function pg_temp.fleet(n int, per int, base bigint, inv_mod int) returns void language plpgsql as $$
begin
  create temp table if not exists f (i int, u uuid, acc uuid, login uuid);
  insert into f select i, gen_random_uuid(), gen_random_uuid(), gen_random_uuid() from generate_series(1, n) i;
  insert into auth.users (id, email) select u, 'plan-' || base || '-' || i || '@t.test' from f where i <= n;
  insert into billing.accounts (id, user_id, market, trial_started_at, trial_ends_at)
  select acc, u, 'ZA', now() - interval '1 day', now() + interval '6 days' from f;
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind)
  select login, u, 'plan-' || base || '-' || i, 'active', 'login' from f;
  insert into billing.logins (id, account, brand, username) select login, acc, 'sunsynk', 'plan-' || base || '-' || i from f;
  insert into billing.plants (id, brand, external_id)
  select base + (i - 1) * per + k, 'sunsynk', (base + (i - 1) * per + k)::text from f, generate_series(0, per - 1) k;
  insert into billing.login_plants (login, plant, plant_name, last_seen_at)
  select login, base + (i - 1) * per + k, 'P' || k, now() from f, generate_series(0, per - 1) k;
  insert into billing.seats (account, plant, chosen_at)
  select acc, base + (i - 1) * per + k, now() - interval '1 hour' from f, generate_series(0, per - 1) k;
  insert into private.inverters (sn, plant_id)
  select 'SN' || p || '-' || x, p from (select base + (i - 1) * per + k as p from f, generate_series(0, per - 1) k) q,
         generate_series(1, 1 + (p % inv_mod)::int) x
   where p % 7 <> 0;
  drop table f;
end $$;

-- ---------------------------------------------------------------------------
-- a. Small fleet: 30 logins of 2 plants, a heavy login, a share login with claims.
-- ---------------------------------------------------------------------------
select pg_temp.fleet(30, 2, 965000000, 3);
-- a heavy login: 12 plants of 4 inverters (48 > the 28 cap): a shard of its own
select pg_temp.fleet(1, 12, 965100000, 1);
-- 12 seats need more than the week's 5 places
insert into billing.grants (account, places, reason, starts_at)
select l.account, 12, 'test', now() - interval '1 day' from billing.logins l where l.username = 'plan-965100000-1';
insert into private.inverters (sn, plant_id)
select 'H' || p || '-' || x, p from generate_series(965100000, 965100011) p, generate_series(1, 3) x where p % 7 <> 0;
-- the share login, with 3 claims from 3 accounts (if the database has none yet)
do $$
declare s uuid; o uuid := gen_random_uuid(); a uuid; k int;
begin
  select id into s from private.sunsynk_accounts where kind = 'share';
  if s is null then
    s := gen_random_uuid();
    insert into auth.users (id, email) values (o, 'plan-share@t.test');
    insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values (s, o, 'plan-share', 'active', 'share');
  end if;
  for k in 1 .. 3 loop
    a := gen_random_uuid(); o := gen_random_uuid();
    insert into auth.users (id, email) values (o, 'plan-claim-' || k || '@t.test');
    insert into billing.accounts (id, user_id, market, trial_started_at, trial_ends_at)
    values (a, o, 'ZA', now() - interval '1 day', now() + interval '6 days');
    insert into billing.plants (id, brand, external_id) values (965200000 + k, 'sunsynk', (965200000 + k)::text);
    insert into billing.plant_claims (plant, account) values (965200000 + k, a);
    insert into billing.seats (account, plant, chosen_at) values (a, 965200000 + k, now() - interval '1 hour');
  end loop;
end $$;
-- one account whose week ended: its plant is not read
update billing.accounts set trial_started_at = now() - interval '10 days', trial_ends_at = now() - interval '3 days'
 where id = (select l.account from billing.logins l where l.username = 'plan-965000000-30');

select pg_temp.eq('mode as shipped', (select mode from private.poll_mode), 'shadow');
create temp table m0 as select date_trunc('minute', now()) - interval '1 hour' as m;
select private.poll_plan_build((select m from m0));
select pg_temp.eq('plan = poll_jobs_v2 pick, every plant', pg_temp.diff((select m from m0)), 0::bigint);
select pg_temp.ok('ended week not planned',
  not exists (select 1 from private.poll_plan where minute = (select m from m0)
                 and plant in (select lp.plant from billing.login_plants lp join billing.logins l on l.id = lp.login
                                where l.username = 'plan-965000000-30')));
select pg_temp.ok('claims planned through the share login',
  (select count(*) = 3 and bool_and(via_share) from private.poll_plan
    where minute = (select m from m0) and plant between 965200001 and 965200003));
select pg_temp.eq('stamped shadow', (select mode from private.poll_plan_minutes where minute = (select m from m0)), 'shadow');
select pg_temp.ok('shard 0 exists', exists (select 1 from private.poll_plan_shards where minute = (select m from m0) and shard = 0));
select pg_temp.ok('shards numbered 0..n-1 and counted',
  (select count(*) = max(shard) + 1 and count(*) = (select shards from private.poll_plan_minutes where minute = (select m from m0))
     from private.poll_plan_shards where minute = (select m from m0)));
select pg_temp.ok('no shard over 28 inverters unless one login, none over 10 logins',
  not exists (select 1 from private.poll_plan_shards where minute = (select m from m0)
                 and ((inverters > 28 and logins > 1) or logins > 10)));
select pg_temp.ok('a login never split',
  not exists (select lane from private.poll_plan where minute = (select m from m0) group by lane having count(distinct shard) > 1));
select pg_temp.ok('the heavy login alone in its shard',
  (select count(distinct pp.lane) = 1 from private.poll_plan pp
    where pp.minute = (select m from m0)
      and pp.shard = (select shard from private.poll_plan pp2 join billing.logins l on l.id = pp2.lane
                       where pp2.minute = (select m from m0) and l.username = 'plan-965100000-1' limit 1)));
select pg_temp.ok('slots 0-20 s, round robin',
  not exists (select 1 from private.poll_plan_shards where minute = (select m from m0) and slot_ms <> (shard % 5) * 5000));
select pg_temp.ok('shard counts add up',
  (select sum(plants) = (select count(*) from private.poll_plan where minute = (select m from m0))
     from private.poll_plan_shards where minute = (select m from m0)));
select pg_temp.eq('built once: a second call keeps the first',
  (private.poll_plan_build((select m from m0))).built_at,
  (select built_at from private.poll_plan_minutes where minute = (select m from m0)));

-- a crash empties the unlogged plan tables but keeps the minute's row: the next call rebuilds
create temp table m9 as select date_trunc('minute', now()) - interval '3 hours' as m;
select private.poll_plan_build((select m from m9));
delete from private.poll_plan_shards where minute = (select m from m9);
delete from private.poll_plan where minute = (select m from m9);
select private.poll_plan_build((select m from m9));
select pg_temp.ok('after a crash the plan is built again',
  exists (select 1 from private.poll_plan_shards where minute = (select m from m9))
  and pg_temp.diff((select m from m9)) = 0);

-- ---------------------------------------------------------------------------
-- b. poll_plan_jobs: rows as planned, re-checked against today's state
-- ---------------------------------------------------------------------------
create temp table j0 as select * from public.poll_plan_jobs(extract(epoch from (select m from m0))::bigint, 0);
select pg_temp.eq('shard 0 reads all it was given',
  (select count(*) from j0), (select count(*) from private.poll_plan where minute = (select m from m0) and shard = 0));
select pg_temp.ok('jobs carry token login and plant version',
  not exists (select 1 from j0 j join private.poll_plan pp on pp.minute = (select m from m0) and pp.plant = j.plant_id
               where j.account_id <> pp.lane or j.plant_version is null));
select pg_temp.eq('read stats on the shard', (select (jobs, dropped)::text from private.poll_plan_shards
                                                where minute = (select m from m0) and shard = 0),
                  (select ((select count(*) from j0)::int, 0)::text));

-- a seat closed, a login broken, a claim gone, a share login down: each planned plant dropped
create temp table victims as
select (select plant from private.poll_plan pp join billing.logins l on l.id = pp.lane
         where pp.minute = (select m from m0) and l.username = 'plan-965000000-1' order by plant limit 1) as seat_closed,
       (select l.id from billing.logins l where l.username = 'plan-965000000-2') as broken_login;
update billing.seats set closed_at = now(), close_reason = 'dropped'
 where plant = (select seat_closed from victims) and closed_at is null;
update billing.logins set status = 'needs_reconnect' where id = (select broken_login from victims);
delete from billing.plant_claims where plant = 965200001;
create temp table expect as
select pp.shard, count(*) filter (where pp.plant = (select seat_closed from victims)
                                     or pp.lane = (select broken_login from victims)
                                     or pp.plant = 965200001) as dropped,
       count(*) as planned
  from private.poll_plan pp where pp.minute = (select m from m0) group by pp.shard;
do $$
declare s record; n int;
begin
  for s in select * from expect loop
    select count(*) into n from public.poll_plan_jobs(extract(epoch from (select m from m0))::bigint, s.shard);
    perform pg_temp.eq('shard ' || s.shard || ' drops what no longer reads', n, (s.planned - s.dropped)::int);
    perform pg_temp.eq('shard ' || s.shard || ' counts its drops',
      (select dropped from private.poll_plan_shards where minute = (select m from m0) and shard = s.shard), s.dropped::int);
  end loop;
end $$;
select pg_temp.ok('three dropped in all', (select sum(dropped) = 1 + 2 + 1 from expect));
update private.sunsynk_accounts set status = 'needs_relink' where kind = 'share';
select pg_temp.eq('share login down: its claims dropped',
  (select count(*) from public.poll_plan_jobs(extract(epoch from (select m from m0))::bigint,
     (select shard from private.poll_plan where minute = (select m from m0) and plant = 965200002))
   where plant_id in (965200002, 965200003)), 0::bigint);
update private.sunsynk_accounts set status = 'active' where kind = 'share';

do $$ begin
  perform * from public.poll_plan_jobs(extract(epoch from (select m from m0) - interval '1 day')::bigint, 0);
  raise exception 'FAIL a minute with no plan should raise';
exception when sqlstate 'P0002' then raise notice 'PASS  a minute with no plan raises';
end $$;
do $$ begin
  perform * from public.poll_plan_jobs(extract(epoch from (select m from m0))::bigint, 999);
  raise exception 'FAIL a shard not in the plan should raise';
exception when sqlstate 'P0002' then raise notice 'PASS  a shard not in the plan raises';
end $$;
select pg_temp.ok('service_role may read the plan, others not',
  has_function_privilege('service_role', 'public.poll_plan_jobs(bigint, int)', 'execute')
  and not has_function_privilege('anon', 'public.poll_plan_jobs(bigint, int)', 'execute')
  and not has_function_privilege('authenticated', 'public.poll_plan_jobs(bigint, int)', 'execute'));

-- ---------------------------------------------------------------------------
-- c. The shadow check: counts what differs now from the plan
-- ---------------------------------------------------------------------------
select private.poll_plan_check((select m from m0));
select pg_temp.eq('check: missing / extra / moved / dropped',
  (select (missing, extra, moved, dropped)::text from private.poll_plan_minutes where minute = (select m from m0)),
  (select (0, (select count(*) from private.poll_plan_diffs where minute = (select m from m0) and live_lane is null)::int,
           0, (select sum(dropped) from expect)::int + 0)::text));
select pg_temp.ok('check: the closed seat, broken login and lost claim are the extras',
  (select count(*) >= 3 from private.poll_plan_diffs where minute = (select m from m0) and live_lane is null));

-- ---------------------------------------------------------------------------
-- d. Dispatch: shadow posts nothing and the old job polls; live posts each due shard once
-- ---------------------------------------------------------------------------
create temp table posted (path text, body jsonb);
create or replace function private.call_fn(p_path text, p_body jsonb default '{}', p_timeout_ms int default 55000)
returns bigint language sql as $$ insert into posted values (p_path, p_body); select 1::bigint $$;

delete from private.poll_plan_minutes where minute >= date_trunc('minute', clock_timestamp()) - interval '1 minute';
select pg_temp.eq('shadow minute: old job polls', private.poll_minute_mode(), 'shadow');
select pg_temp.eq('shadow: tick posts nothing', private.poll_tick(), 0);
select pg_temp.ok('shadow: poll_shards as before (10 logins a shard)',
  (select count(*) = greatest(1, ceil((select count(*) from private.sunsynk_accounts where status = 'active') / 10.0))
     from private.poll_shards()));

update private.poll_mode set mode = 'live';
select pg_temp.eq('switch waits for the next minute', private.poll_minute_mode(), 'shadow');
delete from private.poll_plan_minutes where minute = date_trunc('minute', clock_timestamp());
delete from private.poll_plan_shards where minute = date_trunc('minute', clock_timestamp());
delete from private.poll_plan where minute = date_trunc('minute', clock_timestamp());
select pg_temp.eq('live minute: old job posts nothing', private.poll_minute_mode(), 'live');
create temp table t1 as select private.poll_tick() as n,
  (extract(epoch from clock_timestamp() - date_trunc('minute', clock_timestamp())) * 1000)::int as ms;
select pg_temp.eq('live: posts the shards whose slot has come',
  (select n from t1),
  (select count(*)::int from private.poll_plan_shards
    where minute = date_trunc('minute', clock_timestamp()) and slot_ms <= (select ms from t1)));
select private.poll_tick();
select private.poll_tick();
select pg_temp.ok('live: never a shard twice',
  not exists (select body->>'shard' from posted group by body->>'shard', body->>'minute' having count(*) > 1));
select pg_temp.ok('live: body carries minute, shard, shards, slot',
  not exists (select 1 from posted where path <> 'poll' or body->>'minute' <> extract(epoch from date_trunc('minute', clock_timestamp()))::bigint::text
                 or body->'shards' is null or body->'slot_ms' is null));
select pg_temp.ok('live: poll_shards lists the plan''s shards',
  (select array_agg(shard order by shard) from private.poll_shards())
  = (select array_agg(shard order by shard) from private.poll_plan_shards where minute = date_trunc('minute', clock_timestamp())));
update private.poll_mode set mode = 'shadow';

-- ---------------------------------------------------------------------------
-- e. Scale: 1,000 logins / 3,000 plants more, plus the small fleet above
-- ---------------------------------------------------------------------------
select pg_temp.fleet(1000, 3, 966000000, 2);
analyze billing.seats; analyze billing.login_plants; analyze billing.logins; analyze private.inverters;
create temp table m1 as select date_trunc('minute', now()) - interval '2 hours' as m;
create temp table built as select (private.poll_plan_build((select m from m1))).*;
select pg_temp.eq('scale: plan = poll_jobs_v2 pick', pg_temp.diff((select m from m1)), 0::bigint);
select pg_temp.ok('scale: no shard over the caps unless one login',
  not exists (select 1 from private.poll_plan_shards where minute = (select m from m1)
                 and ((inverters > 28 and logins > 1) or logins > 10)));
do $$
declare b record; t0 timestamptz; worst int := 0; ms int; s record; old_ms int;
begin
  select * into b from built;
  raise notice 'SCALE plan build: % ms, % shards, % logins, % plants, % inverters',
    b.build_ms, b.shards, b.logins, b.plants, b.inverters;
  for s in select shard from private.poll_plan_shards where minute = (select m from m1) order by plants desc limit 5 loop
    t0 := clock_timestamp();
    perform count(*) from public.poll_plan_jobs(extract(epoch from (select m from m1))::bigint, s.shard);
    ms := (extract(epoch from clock_timestamp() - t0) * 1000)::int;
    worst := greatest(worst, ms);
  end loop;
  t0 := clock_timestamp();
  perform count(*) from public.poll_jobs_v2(0, 3);
  old_ms := (extract(epoch from clock_timestamp() - t0) * 1000)::int;
  raise notice 'SCALE shard read: slowest of the 5 biggest % ms; old poll_jobs_v2 one shard % ms', worst, old_ms;
  raise notice 'SCALE shards per slot: %', (select string_agg(slot_ms / 1000 || 's=' || n, ' ' order by slot_ms)
      from (select slot_ms, count(*) n from private.poll_plan_shards where minute = (select m from m1) group by 1) x);
  raise notice 'SCALE biggest shard: % inverters, % logins',
    (select max(inverters) from private.poll_plan_shards where minute = (select m from m1)),
    (select max(logins) from private.poll_plan_shards where minute = (select m from m1));
  if b.build_ms > 1000 then raise exception 'FAIL scale: plan build % ms > 1000', b.build_ms; end if;
  raise notice 'PASS  scale: plan build under 1 s';
end $$;

rollback;
