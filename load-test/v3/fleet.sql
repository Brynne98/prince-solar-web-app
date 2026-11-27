-- Poller v3 load test (SOLAR-656): the fleet in the database. LOCAL stack only.
-- lt3.load(fleet.mjs's JSON) makes every login with a billing account (a grant with as many
-- places as plants), its plants, seats, inverters and a token the fake SunSynk takes.
-- lt3.clear() removes all of it, readings included.
create schema if not exists lt3;

create or replace function lt3.clear() returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  delete from public.readings where plant_id >= 980000000 and plant_id < 990000000;
  delete from public.strings where plant_id >= 980000000 and plant_id < 990000000;
  delete from public.agg_minute where plant_id >= 980000000 and plant_id < 990000000;
  delete from private.meta where plant_id >= 980000000 and plant_id < 990000000;
  delete from private.inverters where plant_id >= 980000000 and plant_id < 990000000;
  delete from public.plant_config where plant_id >= 980000000 and plant_id < 990000000;
  delete from billing.seats where plant >= 980000000 and plant < 990000000;
  delete from plants.claims where plant >= 980000000 and plant < 990000000;
  delete from plants.login_plants where plant >= 980000000 and plant < 990000000;
  delete from plants.plants where id >= 980000000 and id < 990000000;
  delete from billing.grants where reason = 'lt3';
  delete from plants.logins where username like 'lt%';
  delete from billing.accounts where user_id in (select id from auth.users where email like '%@lt3.invalid');
  delete from auth.users where email like '%@lt3.invalid';
  delete from private.poll_runs;
  delete from plants.brand_calls;
  delete from private.gaps where plant_id >= 980000000 and plant_id < 990000000;
  delete from public.inverter_history where plant_id >= 980000000 and plant_id < 990000000;
  delete from public.plant_energy where plant_id >= 980000000 and plant_id < 990000000;
  delete from history.days where plant >= 980000000 and plant < 990000000;
  delete from history.imports where plant >= 980000000 and plant < 990000000;
  delete from history.totals where plant >= 980000000 and plant < 990000000;
  delete from history.lanes; delete from history.calls;
  if to_regclass('lt3.late') is not null then truncate lt3.late; end if;
  delete from private.history_delete_queue where plant_id >= 980000000 and plant_id < 990000000;
end $$;

create or replace function lt3.load(p jsonb) returns int language plpgsql as $$
declare far constant bigint := 4102444800000;   -- token good until 2100
begin
  set local session_replication_role = replica;
  create temp table _l on commit drop as
    select (row_number() over ())::int as k, x->>'username' as username, x->'plants' as plants,
           gen_random_uuid() as u, gen_random_uuid() as a, gen_random_uuid() as l
      from jsonb_array_elements(p->'logins') x;
  create temp table _p on commit drop as
    select _l.k, _l.u, _l.a, _l.l, (pl->>'id')::bigint as plant, pl->'sns' as sns
      from _l, jsonb_array_elements(_l.plants) pl;
  insert into auth.users (id, aud, role, email, email_confirmed_at)
    select u, 'authenticated', 'authenticated', username || '@lt3.invalid', now() from _l;
  insert into billing.accounts (id, user_id, market) select a, u, 'ZA' from _l;
  insert into billing.grants (account, places, reason, starts_at)
    select a, jsonb_array_length(plants), 'lt3', now() - interval '1 day' from _l;
  insert into plants.logins (id, account, user_id, brand, username, access_token, access_expires_at, status, kind, linked_at)
    select l, a, u, 'sunsynk', username, 'at:' || username, far, 'ok', 'login', now() - interval '1 day' from _l;
  -- the fake plants keep the ids the fleet file gives them (below 1e12, so legacy rows); the
  -- plant_for guard is a trigger, off under session_replication_role = replica above
  insert into plants.plants (id, brand, vendor_id, time_zone, legacy)
    select plant, 'sunsynk', plant::text, 'Africa/Johannesburg', true from _p;
  insert into plants.login_plants (login, plant, plant_name, last_seen_at, linked_at)
    select l, plant, 'Load ' || plant, now(), now() - interval '1 day' from _p;
  insert into billing.seats (account, plant, chosen_at) select a, plant, now() - interval '1 day' from _p;
  insert into public.plant_config (plant_id, has_grid, has_battery, batt_positive_means)
    select plant, true, true, 'discharging' from _p;
  insert into private.inverters (sn, plant_id, account_id)
    select sn, plant, l from _p, jsonb_array_elements_text(sns) sn;

  if p->'share' is not null and p->'share' <> 'null' then
    create temp table _s on commit drop as
      select (pl->>'id')::bigint as plant, pl->'sns' as sns, (row_number() over () - 1)::int as j
        from jsonb_array_elements(p->'share'->'plants') pl;
    create temp table _c on commit drop as
      select c, gen_random_uuid() as u, gen_random_uuid() as a from generate_series(0, (p->'share'->>'claimers')::int - 1) c;
    insert into auth.users (id, aud, role, email, email_confirmed_at)
      select u, 'authenticated', 'authenticated', 'ltc' || c || '@lt3.invalid', now() from _c;
    insert into billing.accounts (id, user_id, market) select a, u, 'ZA' from _c;
    insert into billing.grants (account, places, reason, starts_at)
      select a, 5, 'lt3', now() - interval '1 day' from _c;
    insert into auth.users (id, aud, role, email, email_confirmed_at)
      values ('00000000-0000-4000-8000-0000000003a3', 'authenticated', 'authenticated', 'ltshare@lt3.invalid', now())
      on conflict do nothing;
    insert into plants.logins (id, user_id, brand, username, access_token, access_expires_at, status, kind)
      values ('00000000-0000-4000-8000-0000000003a4', '00000000-0000-4000-8000-0000000003a3', 'sunsynk', p->'share'->>'username',
              'at:' || (p->'share'->>'username'), far, 'ok', 'share');
    insert into plants.plants (id, brand, vendor_id, time_zone, legacy)
      select plant, 'sunsynk', plant::text, 'Africa/Johannesburg', true from _s;
    insert into plants.login_plants (login, plant, plant_name, last_seen_at)
      select '00000000-0000-4000-8000-0000000003a4', plant, 'Shared ' || plant, now() from _s;
    insert into plants.claims (plant, account, claimed_at, plant_name)
      select s.plant, c.a, now() - interval '1 day', 'Shared ' || s.plant from _s s join _c c on c.c = s.j % (select count(*) from _c);
    insert into billing.seats (account, plant, chosen_at)
      select c.a, s.plant, now() - interval '1 day' from _s s join _c c on c.c = s.j % (select count(*) from _c);
    insert into public.plant_config (plant_id, has_grid, has_battery, batt_positive_means)
      select plant, true, true, 'discharging' from _s;
    insert into private.inverters (sn, plant_id, account_id)
      select sn, plant, '00000000-0000-4000-8000-0000000003a4' from _s, jsonb_array_elements_text(sns) sn;
  end if;
  return (select count(*) from public.poll_routes(array(select generate_series(0, 59)), now()));
end $$;

-- Plant-minutes expected (the routes each minute, recorded by the driver in lt3.expected)
-- against agg_minute rows saved, per minute.
create table if not exists lt3.expected (ts bigint, plant_id bigint, read_second int, primary key (ts, plant_id));
create or replace function lt3.lost(p_from bigint, p_to bigint)
returns table (ts bigint, expected bigint, saved bigint, lost bigint) language sql as $$
  select e.ts, count(*), count(g.plant_id), count(*) - count(g.plant_id)
    from lt3.expected e
    left join public.agg_minute g on g.plant_id = e.plant_id and g.ts = e.ts
   where e.ts between p_from and p_to
   group by e.ts order by e.ts
$$;

-- SOLAR-686 H26: as lt3.lost, the reader's rows only (an import can fill a minute the reader missed)
create or replace function lt3.lost_reader(p_from bigint, p_to bigint)
returns table (ts bigint, expected bigint, saved bigint, lost bigint) language sql as $$
  select e.ts, count(*), count(g.plant_id), count(*) - count(g.plant_id)
    from lt3.expected e
    left join public.agg_minute g on g.plant_id = e.plant_id and g.ts = e.ts and g.source in ('poller', 'poller_partial')
   where e.ts between p_from and p_to
     -- a plant switched out (nobody holds it) or deleted in the run loses its minutes to the
     -- delete job, on purpose (stop deletes at once)
     and e.plant_id not in (select f.plant from lt3.fenced f)
   group by e.ts order by e.ts
$$;

-- SOLAR-686 H26: what History did in the run. Fenced plants (switched out or deleted mid-run) are
-- recorded in lt3.fenced with the time, and their rows counted then (lt3.fence).
create table if not exists lt3.fenced (plant bigint primary key, at timestamptz, how text, minutes bigint, extras bigint);
create or replace function lt3.fence(p_plants bigint[], p_how text) returns void language plpgsql as $$
begin
  insert into lt3.fenced (plant, at, how, minutes, extras)
  select x, clock_timestamp(), p_how,
         (select count(*) from public.agg_minute a where a.plant_id = x and a.source in ('invhistory', 'plantfeed')),
         (select count(*) from public.inverter_history h where h.plant_id = x)
    from unnest(p_plants) x on conflict (plant) do nothing;
  -- a plant is deleted only once no account holds it (billing.purge_now): both close the seats
  update billing.seats set closed_at = clock_timestamp(), close_reason = 'switched' where plant = any (p_plants) and closed_at is null;
  if p_how = 'delete' then
    insert into private.history_delete_queue (plant_id, queued_at) select x, clock_timestamp() from unnest(p_plants) x on conflict do nothing;
    perform history.stop(x, 'deleted') from unnest(p_plants) x;
    perform plants.bump(p_plants);
  end if;
end $$;
create or replace function lt3.history_result(p_from timestamptz, p_to timestamptz) returns jsonb language sql as $$
  select jsonb_build_object(
    'imports', (select jsonb_build_object('total', count(*), 'done', count(*) filter (where status = 'done'),
                  'stopped', count(*) filter (where status = 'stopped'),
                  'done_p50_min', round((percentile_cont(0.5) within group (order by extract(epoch from finished_at - requested_at) / 60)
                                         filter (where status = 'done'))::numeric, 1),
                  'done_max_min', round(max(extract(epoch from finished_at - requested_at) / 60) filter (where status = 'done')::numeric, 1))
                  from history.imports where plant >= 980000000 and plant < 990000000),
    'days', (select jsonb_object_agg(k, n) from (select why || ':' || kind || ':' || status as k, count(*) as n from history.days
               where plant >= 980000000 and plant < 990000000 group by 1) x),
    'import_days_closed_per_minute', (select jsonb_agg(n order by m) from (
        select date_trunc('minute', closed_at) m, count(*) n from history.days
         where plant >= 980000000 and plant < 990000000 and why = 'import' and closed_at between p_from and p_to group by 1) x),
    'gap_days_closed', (select count(*) from history.days where plant >= 980000000 and why = 'gap' and status <> 'queued'),
    'calls_per_minute', (select jsonb_agg(calls order by minute) from history.calls where minute between p_from and p_to),
    -- rows written after a plant was switched out or deleted, each one as it was written (lt3.late)
    'rows_after_fence', (select count(*) from lt3.late),
    'brand_429', (select jsonb_object_agg(kind, calls) from plants.brand_calls where result in ('429', '403_throttle')),
    'brand_calls_by_kind', (select jsonb_object_agg(kind, calls) from (select kind, sum(calls) calls from plants.brand_calls group by 1) x))
$$;

-- every History row written for a plant after it was fenced, caught as it is written (a later
-- delete cannot hide it)
create table if not exists lt3.late (plant bigint, tbl text, at timestamptz default clock_timestamp());
create or replace function lt3.catch_late() returns trigger language plpgsql as $$
begin
  if exists (select 1 from lt3.fenced f where f.plant = new.plant_id and f.at < clock_timestamp())
     and (tg_table_name <> 'agg_minute' or new.source in ('invhistory', 'plantfeed')) then
    insert into lt3.late (plant, tbl) values (new.plant_id, tg_table_name);
  end if;
  return null;
end $$;
create or replace trigger lt3_late after insert on public.agg_minute for each row execute function lt3.catch_late();
create or replace trigger lt3_late after insert on public.inverter_history for each row execute function lt3.catch_late();
create or replace trigger lt3_late after insert on public.plant_energy for each row execute function lt3.catch_late();
