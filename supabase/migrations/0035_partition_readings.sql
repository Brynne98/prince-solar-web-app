-- ============================================================================
-- 0035 — partition readings and strings by month; downsample old strings.
--
-- ~450 MB per inverter per year lands in these two tables, strings the larger.
-- Everything that reads them wants either the latest minute or a recent window,
-- so monthly range partitions on ts let those scans touch one child, and let old
-- months be thinned or dropped without touching the live one.
--
-- Postgres cannot convert a table in place, so this rebuilds: a partitioned twin
-- created with LIKE (identical columns in identical order, which is what keeps
-- poll_commit's `insert … select *` safe), children for every month on record plus
-- two ahead, the closed months copied while the poller keeps writing (share lock
-- only), then a short exclusive section that copies the live month, checks the
-- counts, and swaps the names. The poller is blocked for that section only.
--
-- Housekeeping that goes with it:
--   private.ensure_partitions(months_ahead)  daily cron, keeps children ahead
--   private.downsample_strings(older_than)   weekly cron, keeps the first row per
--                                            (sn, string, 5-minute bucket) in
--                                            partitions wholly older than 90 days.
--                                            Nothing reads string history older
--                                            than 15 minutes today (api_overview,
--                                            api_alerts_due); this is retention.
--   inverters_cached / poll_commit / q_grid_feed_scale get a ts bound so the
--   per-minute hot path prunes to one child.
-- The two local_day(ts) indexes are not recreated: nothing has read them since
-- 0028 moved day boundaries to local_day_tz on agg_minute.
--
-- Local stack: the copy is a no-op on empty tables; ensure_partitions creates the
-- current month and two ahead. The cron section is skipped where pg_cron is absent.
-- ============================================================================

set statement_timeout = 0;
set lock_timeout = '30s';

-- ---------------------------------------------------------------------------
-- 1. Partition helpers (private; the cron job runs as postgres)
-- ---------------------------------------------------------------------------
-- "FOR VALUES FROM ('1780272000') TO ('1782950400')" -> the FROM or TO epoch.
create or replace function private.partbound_epoch(p_bound text, p_which text)
returns bigint
language sql immutable
set search_path = pg_temp
as $$
  select nullif(regexp_replace(split_part(split_part(p_bound, p_which || ' (', 2), ')', 1), '\D', '', 'g'), '')::bigint
$$;

create or replace function private.ensure_partition_range(
  p_parent regclass, p_prefix text, p_from timestamptz, p_to timestamptz)
returns integer
language plpgsql
set search_path = pg_temp
as $$
declare
  m timestamptz := date_trunc('month', p_from at time zone 'UTC') at time zone 'UTC';
  stop timestamptz := date_trunc('month', p_to at time zone 'UTC') at time zone 'UTC';
  child text; made int := 0;
begin
  while m <= stop loop
    child := format('%s_y%sm%s', p_prefix, to_char(m at time zone 'UTC', 'YYYY'), to_char(m at time zone 'UTC', 'MM'));
    if to_regclass('public.' || child) is null then
      execute format('create table public.%I partition of %s for values from (%s) to (%s)',
        child, p_parent::text,
        extract(epoch from m)::bigint,
        extract(epoch from (m + interval '1 month'))::bigint);
      execute format('alter table public.%I enable row level security', child);
      made := made + 1;
    end if;
    m := m + interval '1 month';
  end loop;
  return made;
end $$;

-- Children for both tables from their earliest month (or now) to now + p_months_ahead.
create or replace function private.ensure_partitions(p_months_ahead integer default 2)
returns integer
language plpgsql
set search_path = pg_temp
as $$
declare t text; lo timestamptz; made int := 0;
begin
  foreach t in array array['readings', 'strings'] loop
    -- earliest existing child bound, else now
    select min(to_timestamp(private.partbound_epoch(pg_get_expr(c.relpartbound, c.oid), 'FROM')))
      into lo
      from pg_inherits i join pg_class c on c.oid = i.inhrelid
     where i.inhparent = ('public.' || t)::regclass;
    made := made + private.ensure_partition_range(
      ('public.' || t)::regclass, t, coalesce(lo, now()), now() + make_interval(months => p_months_ahead));
  end loop;
  return made;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Rebuild readings and strings as partitioned tables
-- ---------------------------------------------------------------------------
do $$
declare
  t text; lo bigint; month_start bigint; n_old bigint; n_new bigint;
  month_start_ts timestamptz := date_trunc('month', now() at time zone 'UTC') at time zone 'UTC';
begin
  if exists (select 1 from pg_partitioned_table p join pg_class c on c.oid = p.partrelid
              where c.relname = 'readings' and c.relnamespace = 'public'::regnamespace) then
    raise notice 'readings already partitioned - skipping rebuild';
    return;
  end if;
  month_start := extract(epoch from month_start_ts)::bigint;

  foreach t in array array['readings', 'strings'] loop
    -- identical columns, defaults and not-nulls, in the same order
    execute format('create table public.%I (like public.%I including defaults including constraints) partition by range (ts)', t || '_p', t);
    execute format('select min(ts) from public.%I', t) into lo;
    perform private.ensure_partition_range(('public.' || t || '_p')::regclass, t,
      coalesce(to_timestamp(lo), now()), now() + interval '2 months');
    -- closed months: share lock only, the poller keeps writing the live month
    execute format('insert into public.%I select * from public.%I where ts < %s', t || '_p', t, month_start);
  end loop;

  -- the short exclusive section: live month, counts, swap
  lock table public.readings, public.strings in access exclusive mode;
  foreach t in array array['readings', 'strings'] loop
    execute format('insert into public.%I select * from public.%I where ts >= %s', t || '_p', t, month_start);
    execute format('select count(*) from public.%I', t) into n_old;
    execute format('select count(*) from public.%I', t || '_p') into n_new;
    if n_old <> n_new then
      raise exception '% copy mismatch: old % new %', t, n_old, n_new;
    end if;
    execute format('drop table public.%I', t);
    execute format('alter table public.%I rename to %I', t || '_p', t);
    raise notice '% rebuilt: % rows', t, n_new;
  end loop;
end $$;

-- keys and indexes on the parents (propagate to every child, present and future)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'readings_pkey') then
    alter table public.readings add constraint readings_pkey primary key (ts, sn);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'strings_pkey') then
    alter table public.strings add constraint strings_pkey primary key (ts, sn, no);
  end if;
end $$;
create index if not exists readings_sn_ts_idx    on public.readings (sn, ts desc);
create index if not exists readings_plant_ts_idx on public.readings (plant_id, ts desc);
create index if not exists strings_plant_ts_idx  on public.strings (plant_id, ts desc);
drop index if exists public.readings_day_idx;
drop index if exists public.strings_day_idx;

-- RLS, policy and grants on the parents, as 0001 (access is always via the parent)
do $$
declare t text;
begin
  foreach t in array array['readings', 'strings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)', t || '_read', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end $$;

-- fresh stack: nothing existed, so make sure the current month and two ahead exist
select private.ensure_partitions(2);

-- ---------------------------------------------------------------------------
-- 3. Hot-path functions get a partition-key bound
-- ---------------------------------------------------------------------------
-- inverters_cached: 0032's body, with a one-day floor on every readings scan.
create or replace function public.inverters_cached(p_account uuid)
returns table (
  sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text,
  gsn text, comm_type text, plant_name text, ord integer, status integer,
  last_reading jsonb, carried_run integer)
language sql
security definer
set search_path = private, pg_temp
as $$
  with floor_ts as (select extract(epoch from now())::bigint - 86400 as t)
  select i.sn, i.plant_id, m.alias, m.model, m.soft_ver, m.hmi_ver,
         m.gsn, m.comm_type, m.plant_name, m.ord, m.status,
         lr.row as last_reading,
         coalesce(cr.n, 0)::integer as carried_run
    from private.inverters i
    left join private.meta m on m.sn = i.sn
    left join lateral (
      select to_jsonb(r) as row
        from public.readings r, floor_ts
       where r.sn = i.sn and r.ts > floor_ts.t
       order by r.ts desc
       limit 1) lr on true
    left join lateral (
      select count(*) as n
        from public.readings r, floor_ts
       where r.sn = i.sn and r.ts > floor_ts.t
         and r.ts > coalesce((select max(r2.ts) from public.readings r2
                               where r2.sn = i.sn and r2.ts > floor_ts.t and not r2.carried), 0)) cr on true
   where i.account_id = p_account
   order by coalesce(m.ord, 9999), i.sn
$$;
revoke all on function public.inverters_cached(uuid) from public, anon, authenticated;
grant execute on function public.inverters_cached(uuid) to service_role;

-- poll_commit: 0030's body; the deletes name p_ts so the planner prunes statically
-- (every staged row carries ts = p_ts).
create or replace function public.poll_commit(
  p_account   uuid,
  p_ts        bigint,
  p_readings  jsonb,
  p_strings   jsonb,
  p_agg       jsonb,
  p_meta      jsonb,
  p_inverters jsonb,
  p_access    text,
  p_expires   bigint
)
returns jsonb
language plpgsql
security definer
set search_path = pg_temp
as $$
declare
  n_readings int := 0;
  n_strings  int := 0;
  gaps       bigint[] := '{}';
  plants     bigint[] := '{}';
  a          record;
  prev_ts    bigint;
begin
  if to_regclass('pg_temp._rd') is not null then drop table _rd; end if;
  if to_regclass('pg_temp._st') is not null then drop table _st; end if;

  create temp table _rd on commit drop as
    select * from jsonb_populate_recordset(null::public.readings, coalesce(p_readings, '[]'::jsonb))
     where plant_id is not null;
  delete from public.readings r using _rd where r.ts = p_ts and r.ts = _rd.ts and r.sn = _rd.sn;
  insert into public.readings select * from _rd;
  get diagnostics n_readings = row_count;

  create temp table _st on commit drop as
    select * from jsonb_populate_recordset(null::public.strings, coalesce(p_strings, '[]'::jsonb))
     where plant_id is not null;
  delete from public.strings s using _st where s.ts = p_ts and s.ts = _st.ts and s.sn = _st.sn and s.no = _st.no;
  insert into public.strings select * from _st;
  get diagnostics n_strings = row_count;

  for a in
    select (r->>'plant_id')::bigint as plant_id,
           nullif(r->>'pv_w',   '')::int as pv_w,
           nullif(r->>'load_w', '')::int as load_w,
           nullif(r->>'batt_w', '')::int as batt_w,
           nullif(r->>'grid_w', '')::int as grid_w,
           nullif(r->>'soc',    '')::int as soc
      from jsonb_array_elements(coalesce(p_agg, '[]'::jsonb)) r
     where r->>'plant_id' is not null
  loop
    plants := plants || a.plant_id;

    select max(ts) into prev_ts from public.agg_minute where plant_id = a.plant_id;
    if prev_ts is not null and p_ts - prev_ts > 90 then
      insert into private.gaps (plant_id, from_ts, to_ts) values (a.plant_id, prev_ts, p_ts)
      on conflict (plant_id, from_ts) do nothing;
      gaps := gaps || a.plant_id;
    end if;

    insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
    values (a.plant_id, p_ts, a.pv_w, a.load_w, a.batt_w, a.grid_w, a.soc, 'poller')
    on conflict (plant_id, ts) do nothing;
  end loop;

  perform public.meta_upsert(coalesce(p_meta, '[]'::jsonb));
  perform public.inverters_seed(coalesce(p_inverters, '[]'::jsonb));
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires,
         last_ok_at = now(), last_error = null
   where id = p_account;

  return jsonb_build_object(
    'readings', n_readings,
    'strings',  n_strings,
    'plants',   to_jsonb(plants),
    'gaps',     to_jsonb(gaps));
end;
$$;
revoke all on function public.poll_commit(uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb, text, bigint)
  from public, anon, authenticated;
grant execute on function public.poll_commit(uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb, text, bigint)
  to service_role;

-- q_grid_feed_scale: 0025's body over the last 30 days (a CT that appeared or
-- vanished more than a month ago is not this plant's current wiring anyway).
create or replace function public.q_grid_feed_scale(p_plant bigint)
returns double precision
language sql stable
set search_path = public, pg_temp
as $$
  with n as (
    select count(distinct sn) as inv,
           count(distinct sn) filter (where grid_import_total_kwh > 0) as ct
      from public.readings
     where plant_id = p_plant and ts >= extract(epoch from now())::bigint - 30 * 86400
  )
  select case when inv > 0 and ct > 0 then inv::double precision / ct else 1 end from n
$$;
revoke all on function public.q_grid_feed_scale(bigint) from public, anon, authenticated;
grant execute on function public.q_grid_feed_scale(bigint) to service_role;

-- ---------------------------------------------------------------------------
-- 4. Downsample old string partitions to one row per 5 minutes
-- ---------------------------------------------------------------------------
create table if not exists private.strings_downsampled (
  partition_name text primary key,
  done_at        timestamptz not null default now(),
  rows_before    bigint,
  rows_after     bigint
);

create or replace function private.downsample_strings(p_older_than_days integer default 90)
returns jsonb
language plpgsql
set search_path = pg_temp
as $$
declare
  c record; cutoff bigint := extract(epoch from now())::bigint - p_older_than_days * 86400;
  hi bigint; before bigint; after bigint; done jsonb := '[]'::jsonb;
begin
  for c in
    select ch.relname as name, pg_get_expr(ch.relpartbound, ch.oid) as bound
      from pg_inherits i join pg_class ch on ch.oid = i.inhrelid
     where i.inhparent = 'public.strings'::regclass
     order by ch.relname
  loop
    hi := private.partbound_epoch(c.bound, 'TO');
    if hi > cutoff then continue; end if;
    if exists (select 1 from private.strings_downsampled d where d.partition_name = c.name) then continue; end if;

    execute format('select count(*) from public.%I', c.name) into before;
    -- keep the first row of each (sn, no, 5-minute bucket): survives gaps, unlike ts %% 300 = 0
    execute format($q$
      delete from public.%1$I p
       where p.ts <> (select min(q.ts) from public.%1$I q
                       where q.sn = p.sn and q.no = p.no and q.ts / 300 = p.ts / 300)$q$, c.name);
    execute format('select count(*) from public.%I', c.name) into after;
    insert into private.strings_downsampled (partition_name, rows_before, rows_after)
    values (c.name, before, after);
    done := done || jsonb_build_object('partition', c.name, 'before', before, 'after', after);
  end loop;
  return done;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Cron: plain SQL jobs, no pg_net. Guarded like 0030.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping partition jobs (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'ensure-partitions') then perform cron.unschedule('ensure-partitions'); end if;
  if exists (select 1 from cron.job where jobname = 'downsample-strings') then perform cron.unschedule('downsample-strings'); end if;
  perform cron.schedule('ensure-partitions',  '0 3 * * *', 'select private.ensure_partitions(2)');
  perform cron.schedule('downsample-strings', '0 4 * * 0', 'select private.downsample_strings(90)');
  raise notice 'scheduled ensure-partitions (daily) and downsample-strings (weekly)';
exception when others then
  raise notice 'partition jobs skipped: %', sqlerrm;
end $$;
