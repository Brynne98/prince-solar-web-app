-- ============================================================================
-- 0025 — scope every api_* and q_* function to one plant.
--
-- 0024 put plant_id on the data tables and RLS behind my_plant_ids(). That already
-- protects SECURITY INVOKER functions for a user with one plant. It does nothing for:
--
--   * SECURITY DEFINER functions (api_overview, api_health, api_alerts_due), which
--     bypass RLS and read every plant;
--   * a user who has linked several plants, where RLS lets all of them through and
--     every aggregate silently mixes sites;
--   * service_role callers (recover, sync-plant-energy, forecast), which bypass RLS.
--
-- Two conventions, kept strictly apart:
--
--   api_*(..., p_plant bigint default null)   browser-facing. Resolves the plant via
--       my_plant(): the caller's only plant when p_plant is null, the given plant if
--       it is theirs, an error otherwise. Existing frontend calls pass nothing and
--       keep working for single-plant users.
--
--   q_*(p_plant bigint, ...)                   helpers. Plant is a required first
--       argument and is trusted — these are reached either from an api_* that has
--       already resolved it, or from an Edge Function with service_role.
--
-- Bodies are otherwise unchanged from their last definitions; only the plant filter
-- and the parameter plumbing are new. Where a function reads the single-site
-- forecast tables (solar_forecast, solar_cal, app_config) it still does — those stay
-- global in this pass — but any join to agg_minute is now per plant.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Resolver
-- ---------------------------------------------------------------------------
create or replace function public.my_plant(p_plant bigint default null)
returns bigint
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $$
declare v bigint;
begin
  -- No session (service_role from an Edge Function or cron) plus an explicit plant:
  -- the caller has already decided which plant it is working on — trust it.
  if auth.uid() is null and p_plant is not null then
    return p_plant;
  end if;
  if p_plant is null then
    select min(plant_id) into v from public.plant_users where user_id = auth.uid();
    if v is null then
      raise exception 'no plant linked to this user' using errcode = 'P0002';
    end if;
    return v;
  end if;
  if exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = p_plant) then
    return p_plant;
  end if;
  raise exception 'plant % is not linked to this user', p_plant using errcode = '42501';
end $$;
revoke all on function public.my_plant(bigint) from public, anon;
grant execute on function public.my_plant(bigint) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- q_* helpers — plant is the required first argument
-- ---------------------------------------------------------------------------
drop function if exists public.q_day_agg(date, text);
create or replace function public.q_day_agg(p_plant bigint, p_day date, p_source text default null)
returns table (hm text, pv_w numeric, load_w numeric, batt_w numeric, grid_w numeric, soc numeric, feed_n bigint, row_n bigint)
language sql stable
set search_path = public, pg_temp
as $$
  select to_char(public.local_ts(min(a.ts)), 'HH24:MI') as hm,
         round(avg(a.pv_w)::numeric)   as pv_w,
         round(avg(a.load_w)::numeric) as load_w,
         round(avg(a.batt_w)::numeric) as batt_w,
         round(avg(a.grid_w)::numeric) as grid_w,
         round(avg(a.soc)::numeric)    as soc,
         sum(case when a.source = 'plantfeed' then 1 else 0 end) as feed_n,
         count(*) as row_n
    from public.agg_minute a
   where a.plant_id = p_plant
     and public.local_day(a.ts) = p_day
     and (p_source is null or a.source = p_source)
   group by public.local_day(a.ts), public.local_hour(a.ts), public.local_minute(a.ts) / 5
   order by min(a.ts)
$$;

drop function if exists public.q_grid_present(bigint);
create or replace function public.q_grid_present(p_plant bigint, p_ts bigint)
returns boolean
language sql stable
set search_path = public, pg_temp
as $$
  select case when count(grid_volt_v) = 0 then null
              else bool_or(grid_volt_v > 100) end
    from public.readings where plant_id = p_plant and ts = p_ts
$$;

drop function if exists public.q_day_gap_minutes(date);
create or replace function public.q_day_gap_minutes(p_plant bigint, p_day date)
returns bigint
language sql stable
set search_path = public, pg_temp
as $$
  with b as (
    select (select min(ts) from public.agg_minute where plant_id = p_plant) as first_ts,
           public.day_start_epoch(p_day)             as day_start,
           extract(epoch from now())::bigint         as now_ts
  ),
  w as (
    select greatest(day_start, first_ts) as lo,
           least(day_start + 86400, now_ts) as hi
      from b where first_ts is not null
  )
  select case when w.hi <= w.lo then null
              else greatest(0, round((w.hi - w.lo) / 60.0)::bigint
                   - (select count(*) from public.agg_minute
                       where plant_id = p_plant and public.local_day(ts) = p_day))
         end
    from w
$$;

drop function if exists public.q_recovered_minutes(date);
create or replace function public.q_recovered_minutes(p_plant bigint, p_day date)
returns bigint
language sql stable
set search_path = public, pg_temp
as $$
  select count(*) from public.agg_minute
   where plant_id = p_plant and source = 'plantfeed' and public.local_day(ts) = p_day
$$;

drop function if exists public.q_missing_minutes(date);
create or replace function public.q_missing_minutes(p_plant bigint, p_day date)
returns table (ts bigint)
language sql stable
set search_path = public, pg_temp
as $$
  with b as (
    select (select min(a.ts) from public.agg_minute a where a.plant_id = p_plant) as first_ts,
           public.day_start_epoch(p_day)                        as day_start,
           extract(epoch from now())::bigint                    as now_ts
  ),
  bounds as (
    select ceil(greatest(day_start, first_ts) / 60.0)::bigint * 60 as lo,
           least(day_start + 86400, now_ts - 600)                  as hi
      from b where first_ts is not null
  )
  select g as ts from bounds, generate_series(bounds.lo, bounds.hi - 60, 60) g
   where bounds.hi > bounds.lo
     and not exists (select 1 from public.agg_minute a where a.plant_id = p_plant and a.ts = g)
$$;

drop function if exists public.q_insert_recovered(jsonb);
create or replace function public.q_insert_recovered(p_plant bigint, p_rows jsonb)
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare n integer;
begin
  with ins as (
    insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
    select p_plant, (r->>'ts')::bigint,
           nullif(r->>'pv_w','')::integer,   nullif(r->>'load_w','')::integer,
           nullif(r->>'batt_w','')::integer, nullif(r->>'grid_w','')::integer,
           nullif(r->>'soc','')::integer,    'plantfeed'
      from jsonb_array_elements(p_rows) r
    on conflict (plant_id, ts) do nothing
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;

drop function if exists public.q_stats();
create or replace function public.q_stats(p_plant bigint)
returns table (agg_rows bigint, days bigint, first_ts bigint, last_ts bigint, per_inverter_rows bigint)
language sql stable
set search_path = public, pg_temp
as $$
  select
    (select count(*) from public.agg_minute where plant_id = p_plant),
    (select count(distinct public.local_day(ts)) from public.agg_minute where plant_id = p_plant),
    (select min(ts) from public.agg_minute where plant_id = p_plant),
    (select max(ts) from public.agg_minute where plant_id = p_plant),
    (select count(*) from public.readings where plant_id = p_plant)
$$;

drop function if exists public.q_grid_feed_scale();
create or replace function public.q_grid_feed_scale(p_plant bigint)
returns double precision
language sql stable
set search_path = public, pg_temp
as $$
  with n as (
    select count(distinct sn) as inv,
           count(distinct sn) filter (where grid_import_total_kwh > 0) as ct
      from public.readings where plant_id = p_plant
  )
  select case when inv > 0 and ct > 0 then inv::double precision / ct else 1 end from n
$$;

drop function if exists public.q_by_hour(integer);
create or replace function public.q_by_hour(p_plant bigint, p_days integer default 14)
returns table (hour integer, pv_w numeric, load_w numeric, baseline_load_w numeric, grid_w numeric, soc numeric, samples bigint, surplus_w numeric, spare_w numeric, solar_w numeric, batt_load_w numeric, grid_load_w numeric)
language sql stable
set search_path = public, pg_temp
as $$
  with since as (select (extract(epoch from now())::bigint - p_days * 86400) as t),
  day_stats as (
    select public.local_day(ts) as d, count(distinct public.local_hour(ts)) as hours
      from public.agg_minute, since where plant_id = p_plant and ts >= since.t group by 1
  ),
  d as (
    select public.local_hour(ts) as hour,
           coalesce(pv_w, 0)   as pv,
           coalesce(load_w, 0) as load,
           coalesce(batt_w, 0) as batt,
           coalesce(grid_w, 0) as grid,
           soc,
           least(coalesce(pv_w, 0), coalesce(load_w, 0)) as s2l
      from public.agg_minute, since
     where plant_id = p_plant and ts >= since.t
       and public.local_day(ts) in (select d from day_stats where hours >= 24)
  ),
  e as (
    select hour, pv, load, batt, grid, soc, s2l, (load - s2l) as rem,
           case when batt < 0 then least(-batt, load - s2l) else 0 end as b2l
      from d
  ),
  base as (
    select hour,
           round(avg(pv)::numeric)   as pv_w,
           round(avg(load)::numeric) as load_w,
           round(avg(case when load < 1500 then load end)::numeric) as baseline_load_w,
           round(avg(grid)::numeric) as grid_w,
           round(avg(soc)::numeric)  as soc,
           count(*)                  as samples,
           round(avg(s2l)::numeric)  as solar_w,
           round(avg(b2l)::numeric)  as batt_load_w,
           round(avg(rem - b2l)::numeric) as grid_load_w
      from e group by 1
  )
  select hour, pv_w, load_w,
         coalesce(baseline_load_w, load_w) as baseline_load_w,
         grid_w, soc, samples,
         round(coalesce(pv_w,0) - coalesce(load_w,0)) as surplus_w,
         round(coalesce(pv_w,0) - coalesce(coalesce(baseline_load_w, load_w),0)) as spare_w,
         solar_w, batt_load_w, grid_load_w
    from base order by hour
$$;

drop function if exists public.q_segment_power(integer);
create or replace function public.q_segment_power(p_plant bigint, p_days integer default 7)
returns table (seg integer, load_w numeric, solar_w numeric, batt_w numeric, grid_w numeric, mins bigint)
language sql stable
set search_path = public, pg_temp
as $$
  with since as (select (extract(epoch from now())::bigint - p_days * 86400) as t),
  d as (
    select public.local_hour(ts) as h,
           coalesce(load_w, 0) as load,
           coalesce(batt_w, 0) as batt,
           least(coalesce(pv_w, 0), coalesce(load_w, 0)) as s2l
      from public.agg_minute, since where plant_id = p_plant and ts >= since.t
  ),
  e as (
    select h, load, s2l, (load - s2l) as rem,
           case when batt < 0 then least(-batt, load - s2l) else 0 end as b2l
      from d
  )
  select (case when h < 4 then 0 when h < 6 then 1 when h < 8 then 2
               when h < 17 then 3 else 4 end)::int as seg,
         round(avg(load)::numeric)       as load_w,
         round(avg(s2l)::numeric)        as solar_w,
         round(avg(b2l)::numeric)        as batt_w,
         round(avg(rem - b2l)::numeric)  as grid_w,
         count(*)                        as mins
    from e group by 1 order by 1
$$;

drop function if exists public.q_cal_samples();
create or replace function public.q_cal_samples(p_plant bigint)
returns table (ts bigint, pv_w integer, soc integer)
language sql stable
set search_path = public, pg_temp
as $$
  with day_stats as (
    select public.local_day(ts) as d, count(distinct public.local_hour(ts)) as hours
      from public.agg_minute where plant_id = p_plant group by 1
  )
  select a.ts, a.pv_w, a.soc from public.agg_minute a
   where a.plant_id = p_plant
     and a.pv_w > 800 and a.soc < 85
     and public.local_day(a.ts) in (select d from day_stats where hours >= 24)
$$;

-- Forecast calibration: irradiance is single-site (solar_forecast), production is
-- per plant. These are only ever called by the forecast function for the
-- calibration plant, so plant is required here too.
drop function if exists public.q_forecast_cal_samples(integer);
create or replace function public.q_forecast_cal_samples(p_plant bigint, p_days integer default 120)
returns table (ts bigint, gti double precision, pv_w double precision)
language sql stable
set search_path = public, pg_temp
as $$
  select f.ts, f.gti_wm2, avg(a.pv_w)::double precision
    from public.solar_forecast f
    join public.agg_minute a
      on a.plant_id = p_plant and a.ts between f.ts - 300 and f.ts + 300
   where f.gti_wm2 > 150
     and f.ts > extract(epoch from now())::bigint - p_days * 86400
     and a.soc < 85
   group by f.ts, f.gti_wm2
  having count(*) >= 5
$$;

drop function if exists public.q_forecast_cal_days(integer);
create or replace function public.q_forecast_cal_days(p_plant bigint, p_days integer default 120)
returns table (day date, pv_kwh double precision, gti_kwh double precision, ratio double precision)
language sql stable
set search_path = public, pg_temp
as $$
  with irr as (
    select public.local_day(ts) as day,
           sum(case when ts2 is not null and ts2 - ts <= 7200
                    then (gti_wm2 + gti2) / 2.0 * (ts2 - ts) / 3600.0 else 0 end) / 1000.0 as gti_kwh
      from (select ts, gti_wm2,
                   lead(ts)      over (order by ts) as ts2,
                   lead(gti_wm2) over (order by ts) as gti2
              from public.solar_forecast) f
     group by 1
  ),
  logged as (
    select public.local_day(ts) as day,
           sum(pv_w) / 60000.0 as pv_kwh,
           count(*)            as minutes,
           avg(soc)            as avg_soc
      from public.agg_minute where plant_id = p_plant group by 1
  )
  select l.day, l.pv_kwh, i.gti_kwh, l.pv_kwh / i.gti_kwh
    from logged l join irr i using (day)
   where l.minutes >= 1400
     and i.gti_kwh > 3
     and l.avg_soc < 85
     and l.day > (now() at time zone 'Africa/Johannesburg')::date - p_days
$$;

drop function if exists public.q_recompute_solar_scale();
create or replace function public.q_recompute_solar_scale(p_plant bigint)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare n int; picked double precision; result int;
begin
  create temp table if not exists _ratios (r double precision) on commit drop;
  delete from _ratios;
  insert into _ratios
  select pv_w / shape from (
    select c.pv_w, public.clear_sky_shape(c.ts) as shape from public.q_cal_samples(p_plant) c
  ) s where shape > 0.25;
  select count(*) into n from _ratios;
  if n >= 20 then
    select r into picked from _ratios
     order by r offset (floor(n * public.cfg('SOLAR_CAL_PERCENTILE')))::int limit 1;
  end if;
  result := round(least(
    coalesce(picked, public.cfg('SYSTEM_KWP') * 1000 * 0.82),
    public.cfg('SYSTEM_KWP') * 1000 * public.cfg('SOLAR_CAL_CAP_MULT')))::int;
  update public.solar_cal
     set scale_w = result, samples = n, computed_at = now()
   where id = 1;
  return jsonb_build_object('scaleW', result, 'samples', n);
end $$;

-- ---------------------------------------------------------------------------
-- api_* — browser-facing, plant resolved via my_plant()
-- ---------------------------------------------------------------------------

drop function if exists public.api_overview();
create or replace function public.api_overview(p_plant bigint default null)
returns jsonb
language sql
stable security definer
set search_path = public, private, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  latest as (select max(ts) as ts from public.readings where plant_id = (select id from pl)),
  r as (select rd.* from public.readings rd, latest where rd.plant_id = (select id from pl) and rd.ts = latest.ts),
  st as (
    select s.sn, jsonb_agg(jsonb_build_object(
             'id', null, 'no', s.no, 'power', s.power_w,
             'voltage', s.volt_v, 'current', s.current_a, 'today', s.today_kwh)
           order by s.no) as strings
      from public.strings s, latest
     where s.plant_id = (select id from pl) and s.ts = latest.ts group by s.sn
  ),
  inv as (
    select r.sn,
           jsonb_build_object(
             'sn', r.sn,
             'alias', coalesce(m.alias, r.sn),
             'model', m.model,
             'status', r.status,
             'gsn', m.gsn,
             'soft', m.soft_ver,
             'hmi', m.hmi_ver,
             'commType', m.comm_type,
             'pv', jsonb_build_object(
               'power', round(r.pv_w), 'today', r.pv_today_kwh, 'total', r.pv_total_kwh,
               'strings', coalesce(st.strings, '[]'::jsonb)),
             'battery', jsonb_build_object(
               'power', round(abs(r.batt_w)),
               'signedPower', round(r.batt_w),
               'status', case when r.batt_w > 5 then 'charging'
                              when r.batt_w < -5 then 'discharging' else 'idle' end,
               'soc', r.batt_soc, 'voltage', r.batt_voltage_v, 'current', r.batt_current_a,
               'temperature', r.batt_temp_c,
               'capacity', m.capacity_ah, 'numberOfBatteries', m.number_of_batteries,
               'todayCharged', r.batt_chg_today_kwh, 'todayDischarged', r.batt_dischg_today_kwh,
               'totalCharged', r.batt_chg_total_kwh, 'totalDischarged', r.batt_dischg_total_kwh),
             'grid', jsonb_build_object(
               'power', round(r.grid_w),
               'direction', case when r.grid_w >= 0 then 'importing' else 'exporting' end,
               'todayImport', r.grid_import_today_kwh, 'todayExport', r.grid_export_today_kwh,
               'totalImport', r.grid_import_total_kwh, 'totalExport', r.grid_export_total_kwh,
               'frequency', r.grid_freq_hz, 'powerFactor', r.grid_pf),
             'load', jsonb_build_object(
               'power', round(r.load_w), 'today', r.load_today_kwh,
               'total', r.load_total_kwh, 'frequency', r.load_freq_hz),
             'output', jsonb_build_object(
               'power', round(r.output_w), 'voltage', r.output_volt_v,
               'frequency', r.output_freq_hz)) as snap,
           r.pv_w, r.load_w, r.grid_w, r.batt_w, r.batt_soc,
           r.pv_today_kwh, r.grid_import_today_kwh, r.grid_export_today_kwh,
           coalesce(m.ord, 9999) as ord
      from r
      left join private.meta m on m.sn = r.sn
      left join st on st.sn = r.sn
  ),
  totals as (
    select sum(round(pv_w)) as pv, sum(round(load_w)) as load,
           sum(round(grid_w)) as grid, sum(round(batt_w)) as batt,
           avg(batt_soc) filter (where batt_soc > 0) as soc,
           sum(pv_today_kwh) as today_pv,
           sum(grid_import_today_kwh) as today_imp,
           sum(grid_export_today_kwh) as today_exp
      from inv
  ),
  gp as (
    select public.q_grid_present((select id from pl), (select ts from latest)) as present
  ),
  grid_today as (
    select coalesce(sum(case when grid_w > 0 then grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           coalesce(sum(case when grid_w < 0 then -grid_w * (5.0/60) / 1000 else 0 end), 0) as exp,
           count(*) as n
      from public.q_day_agg((select id from pl), (now() at time zone 'Africa/Johannesburg')::date, null)
  ),
  plant as (
    select pu.plant_id as id, pu.plant_name as name
      from public.plant_users pu where pu.plant_id = (select id from pl) and pu.user_id = auth.uid()
      limit 1
  )
  select jsonb_build_object(
    'generatedAt', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'plant', jsonb_build_object(
      'id', (select id from plant),
      'name', coalesce((select name from plant), 'Home · SunSynk')),
    'totals', jsonb_build_object(
      'pv', t.pv, 'load', t.load, 'grid', t.grid,
      'gridDirection', case when t.grid >= 0 then 'importing' else 'exporting' end,
      'batteryPower', abs(t.batt),
      'batteryDirection', case when abs(t.batt) <= 5 then 'idle'
                               when t.batt > 0 then 'charging' else 'discharging' end,
      'soc', case when t.soc is null then null else round(t.soc) end,
      'todayPv', round(t.today_pv::numeric, 2),
      'todayGridImport', round((case when g.n > 5 then g.imp else t.today_imp end)::numeric, 2),
      'todayGridExport', round((case when g.n > 5 then g.exp else t.today_exp end)::numeric, 2),
      'gridPresent', (select present from gp)),
    'config', jsonb_build_object(
      'battCapacity', public.cfg('BATTERY_KWH'),
      'reserve',      public.cfg('BATTERY_RESERVE_PCT')),
    'inverters', coalesce((select jsonb_agg(snap order by ord, sn) from inv), '[]'::jsonb))
  from totals t, grid_today g
$$;

drop function if exists public.api_history(date);
create or replace function public.api_history(p_date date default null, p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  d as (
    select coalesce(p_date, (now() at time zone 'Africa/Johannesburg')::date) as day
  ),
  agg as (
    select (split_part(a.hm, ':', 1)::int) * 12 + (split_part(a.hm, ':', 2)::int / 5) as bkt,
           a.pv_w, a.batt_w, a.grid_w, a.load_w, a.soc, a.feed_n, a.row_n
      from d, public.q_day_agg((select id from pl), d.day, null) a
  ),
  n as (select count(*) as c, coalesce(max(bkt), 0) as mx from agg),
  lastb as (
    select case when (select day from d) = (now() at time zone 'Africa/Johannesburg')::date
                then (select mx from n) else 287 end as lb
  ),
  buckets as (
    select g.i as bkt, a.pv_w, a.batt_w, a.grid_w, a.load_w, a.soc, a.feed_n, a.row_n
      from lastb, generate_series(0, (select lb from lastb)) as g(i)
      left join agg a on a.bkt = g.i
  ),
  defs as (
    select * from (values
      ('PV', 'W', 'pv', 1),
      ('Battery', 'W', 'battflip', 2),
      ('Grid', 'W', 'grid', 3),
      ('Load', 'W', 'load', 4),
      ('SOC', '%', 'soc', 5)
    ) as t(label, unit, field, ord)
  )
  select case when (select c from n) <= 5
    then jsonb_build_object('date', (select day from d)::text, 'series', '[]'::jsonb, 'approx', true)
    else jsonb_build_object(
      'date', (select day from d)::text,
      'gapMinutes', public.q_day_gap_minutes((select id from pl), (select day from d)),
      'recoveredMinutes', public.q_recovered_minutes((select id from pl), (select day from d)),
      'series', (
        select jsonb_agg(ser order by ord) from (
          select f.ord, jsonb_build_object('label', f.label, 'unit', f.unit, 'points', (
            select jsonb_agg(
              jsonb_build_object('time', public._hm(b.bkt), 'value',
                case when b.row_n is null then null
                     when f.field = 'pv'       then coalesce(b.pv_w, 0)
                     when f.field = 'battflip' then -coalesce(b.batt_w, 0)
                     when f.field = 'grid'     then coalesce(b.grid_w, 0)
                     when f.field = 'load'     then coalesce(b.load_w, 0)
                     else b.soc end)
              || case when b.row_n is not null and b.feed_n > 0 and b.feed_n >= b.row_n
                      then jsonb_build_object('est', true) else '{}'::jsonb end
              order by b.bkt)
            from buckets b)) as ser
          from defs f) x))
    end
$$;

drop function if exists public.api_balance();
create or replace function public.api_balance(p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  now_s as (select extract(epoch from now())::bigint as t),
  bal as (
    select r.ts,
           max(r.batt_soc) - min(r.batt_soc) as socspread,
           max(r.batt_voltage_v) - min(r.batt_voltage_v) as vspread
      from public.readings r, now_s
     where r.plant_id = (select id from pl)
       and r.ts >= now_s.t - 72 * 3600
       and r.batt_soc is not null and r.batt_soc between 1 and 100
     group by r.ts
    having count(distinct r.sn) = 2 and (max(r.batt_soc) - min(r.batt_soc)) <= 25
  ),
  last_r as (select * from bal order by ts desc limit 1),
  win as (
    select count(*) >= 2 and (max(ts) - min(ts)) >= 9 * 60 as have_window,
           min(socspread) as min_spread
      from bal, now_s where bal.ts >= now_s.t - 600
  ),
  spreads as (
    select (select round(socspread * 10) / 10 from last_r) as soc_spread,
           (select round(vspread * 100) / 100 from last_r) as v_spread
  ),
  st as (
    select case when s.soc_spread is null then 'unknown'
                when not coalesce(w.have_window, false) then 'balanced'
                when w.min_spread >= 5 then 'drifting'
                when w.min_spread >= 3 then 'watch'
                else 'balanced' end as status,
           case when s.soc_spread is null then 'unknown'
                when s.soc_spread < 3 then 'balanced'
                when s.soc_spread < 5 then 'watch'
                else 'drifting' end as live_band,
           s.soc_spread, s.v_spread
      from spreads s, win w
  ),
  health as (
    select (select batt_temp_c from public.readings
             where plant_id = (select id from pl) and batt_temp_c > 0 and batt_temp_c < 80
             order by ts desc limit 1) as temp_c,
           (select coalesce(round(sum(case when soc >= 98 then 1 else 0 end) / 60.0, 1), 0)
              from public.agg_minute
             where plant_id = (select id from pl)
               and public.local_day(ts) = (now() at time zone 'Africa/Johannesburg')::date) as hrs_full
  )
  select jsonb_build_object(
    'banks', coalesce((select jsonb_agg(jsonb_build_object(
                'sn', sn, 'soc', batt_soc, 'voltage', batt_voltage_v, 'current', batt_current_a)
              order by sn)
              from public.readings
             where plant_id = (select id from pl)
               and ts = (select max(ts) from public.readings
                          where plant_id = (select id from pl) and batt_soc is not null)), '[]'::jsonb),
    'socSpread', st.soc_spread,
    'vSpread', st.v_spread,
    'status', st.status,
    'pending', st.live_band not in ('unknown', 'balanced') and st.status = 'balanced',
    'max24h', (select round(max(socspread) * 10) / 10 from bal, now_s where bal.ts >= now_s.t - 24 * 3600),
    'max72h', (select round(max(socspread) * 10) / 10 from bal),
    'samples', (select count(*) from bal),
    'tempC', h.temp_c,
    'hrsAtFullToday', h.hrs_full,
    'tempHot', h.temp_c is not null and h.temp_c > 35,
    'stale', (select ts from last_r) is null
             or ((select t from now_s) - (select ts from last_r)) > 600)
  from st, health h
$$;

drop function if exists public.api_energy(text);
create or replace function public.api_energy(p_period text default 'week', p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  today as (select (now() at time zone 'Africa/Johannesburg')::date as d),
  period as (select case when p_period in ('week','month','year','lifetime') then p_period else 'week' end as p),
  rows as (
    select e.* from public.plant_energy e, today, period
     where e.plant_id = (select id from pl)
       and case period.p
             when 'week'  then e.bucket = 'day'
                            and e.period >= date_trunc('week', today.d)::date
                            and e.period <= today.d
             when 'month' then e.bucket = 'day'
                            and e.period >= date_trunc('month', today.d)::date
                            and e.period <= today.d
             when 'year'  then e.bucket = 'month'
                            and extract(year from e.period) = extract(year from today.d)
             else              e.bucket = 'month'
           end
  )
  select jsonb_build_object(
    'period', (select p from period),
    'rows', coalesce((select jsonb_agg(public._energy_row(r.bucket, r.period, r.pv_kwh, r.load_kwh, r.imp_kwh, r.exp_kwh, r.chg_kwh, r.dischg_kwh) order by r.period) from rows r), '[]'::jsonb))
$$;

drop function if exists public.api_history_earliest();
create or replace function public.api_history_earliest(p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object('earliest', (
    select to_char(min(period), 'YYYY-MM-DD') from public.plant_energy
     where plant_id = public.my_plant(p_plant)
       and bucket = 'day'
       and (coalesce(pv_kwh,0) > 0 or coalesce(load_kwh,0) > 0
            or coalesce(imp_kwh,0) > 0 or coalesce(exp_kwh,0) > 0
            or coalesce(chg_kwh,0) > 0 or coalesce(dischg_kwh,0) > 0)))
$$;

drop function if exists public.api_trends_daily(integer);
create or replace function public.api_trends_daily(p_days integer default 30, p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  d as (select least(greatest(coalesce(p_days, 30), 1), 120) as n),
  t as (select (now() at time zone 'Africa/Johannesburg')::date as today),
  live as (
    select (select today from t)                      as period,
           sum(pv_w)   / 60000.0                      as pv_kwh,
           sum(load_w) / 60000.0                      as load_kwh,
           sum(greatest(grid_w, 0))  / 60000.0        as imp_kwh,
           sum(greatest(-grid_w, 0)) / 60000.0        as exp_kwh,
           sum(greatest(batt_w, 0))  / 60000.0        as chg_kwh,
           sum(greatest(-batt_w, 0)) / 60000.0        as dischg_kwh
      from public.agg_minute
     where plant_id = (select id from pl)
       and public.local_day(ts) = (select today from t)
    having count(*) > 0
  ),
  cached as (
    select e.period, e.pv_kwh, e.load_kwh, e.imp_kwh, e.exp_kwh, e.chg_kwh, e.dischg_kwh
      from public.plant_energy e, d, t
     where e.plant_id = (select id from pl) and e.bucket = 'day' and e.period < t.today
     order by e.period desc limit (select n from d)
  ),
  merged as (select * from cached union all select * from live),
  top as (select * from merged order by period desc limit (select n from d)),
  expected as (
    select public.local_day(ts) as period,
           sum(case when ts2 is not null and ts2 - ts <= 7200
                    then (gti_wm2 + gti2) / 2.0 * (ts2 - ts) / 3600.0 else 0 end)
             / 1000.0 * public.forecast_k_day() as kwh
      from (select ts, gti_wm2,
                   lead(ts)      over (order by ts) as ts2,
                   lead(gti_wm2) over (order by ts) as gti2
              from public.solar_forecast) f
     group by 1
  )
  select jsonb_build_object('days', (select n from d),
    'rows', coalesce((
      select jsonb_agg(
               public._energy_row('day', x.period, x.pv_kwh, x.load_kwh,
                                  x.imp_kwh, x.exp_kwh, x.chg_kwh, x.dischg_kwh)
               || case when e.kwh is not null
                       then jsonb_build_object('expected', round(e.kwh::numeric, 1))
                       else '{}'::jsonb end
               order by x.period)
        from top x left join expected e on e.period = x.period), '[]'::jsonb))
$$;

drop function if exists public.api_trends_monthly();
create or replace function public.api_trends_monthly(p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object('rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'ym', to_char(period, 'YYYY-MM'),
             'year', extract(year from period)::int,
             'month', extract(month from period)::int,
             'label', to_char(period, 'Mon'),
             'pv', pv_kwh, 'load', load_kwh, 'imp', imp_kwh, 'exp', exp_kwh)
           order by period)
      from public.plant_energy
     where plant_id = public.my_plant(p_plant) and bucket = 'month'), '[]'::jsonb))
$$;

drop function if exists public.api_trends_compare();
create or replace function public.api_trends_compare(p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  t as (select (now() at time zone 'Africa/Johannesburg')::date as d),
  b as (
    select d,
           d - 1                                              as yesterday,
           date_trunc('week', d)::date                        as week_start,
           (date_trunc('week', d) - interval '7 days')::date  as prev_week_start,
           d - 7                                              as prev_week_end,
           date_trunc('month', d)::date                       as month_start,
           (date_trunc('month', d) - interval '1 month')::date as last_month_start,
           ((date_trunc('month', d) - interval '1 month') + (extract(day from d)::int - 1) * interval '1 day')::date as last_month_same_day,
           date_trunc('year', d)::date                        as year_start,
           (date_trunc('year', d) - interval '1 year')::date  as last_year_start,
           ((date_trunc('year', d) - interval '1 year') + (d - date_trunc('year', d)::date) * interval '1 day')::date as last_year_same_day
      from t
  ),
  agg as (
    select 'today'      as k, 'cur'  as side, b.d as lo, b.d as hi from b
    union all select 'today', 'prev', b.yesterday, b.yesterday from b
    union all select 'week',  'cur',  b.week_start, b.d from b
    union all select 'week',  'prev', b.prev_week_start, b.prev_week_end from b
    union all select 'month', 'cur',  b.month_start, b.d from b
    union all select 'month', 'prev', b.last_month_start, b.last_month_same_day from b
    union all select 'year',  'cur',  b.year_start, b.d from b
    union all select 'year',  'prev', b.last_year_start, b.last_year_same_day from b
  ),
  sums as (
    select a.k, a.side,
           jsonb_build_object(
             'pv',   coalesce(round(sum(e.pv_kwh)::numeric, 1), 0),
             'load', coalesce(round(sum(e.load_kwh)::numeric, 1), 0),
             'imp',  coalesce(round(sum(e.imp_kwh)::numeric, 1), 0)) as v
      from agg a
      left join public.plant_energy e
        on e.plant_id = (select id from pl) and e.bucket = 'day' and e.period between a.lo and a.hi
     group by a.k, a.side
  )
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from (
    select k, jsonb_object_agg(side, v) as v from sums group by k) x
$$;

-- Potential curve is built from the single-site calibration (solar_cal); the plant
-- argument is accepted for a consistent call signature and to assert access.
drop function if exists public.api_trends_potential(date);
create or replace function public.api_trends_potential(p_date date default null, p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  d as (select coalesce(p_date, (now() at time zone 'Africa/Johannesburg')::date) as day),
  s as (select public.solar_scale_w() as scale),
  day0 as (select public.day_start_epoch((select day from d)) as t0)
  select jsonb_build_object(
    'date', (select day from d)::text,
    'scaleW', (select scale from s),
    'points', coalesce((
      select jsonb_agg(jsonb_build_object(
               't', t,
               'w', round((select scale from s) * public.clear_sky_shape((select t0 from day0) + t * 60))) order by t)
        from generate_series(0, 1435, 5) t), '[]'::jsonb))
  from pl
$$;

drop function if exists public.api_trends_by_hour(integer);
create or replace function public.api_trends_by_hour(p_days integer default 14, p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object('days', p_days,
    'hours', coalesce((select jsonb_agg(to_jsonb(h) order by h.hour)
                         from public.q_by_hour(public.my_plant(p_plant), p_days) h), '[]'::jsonb))
$$;

drop function if exists public.api_trends_segments(integer);
create or replace function public.api_trends_segments(p_days integer default 7, p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object('days', p_days,
    'segments', coalesce((select jsonb_agg(to_jsonb(s) order by s.seg)
                            from public.q_segment_power(public.my_plant(p_plant), p_days) s), '[]'::jsonb))
$$;

drop function if exists public.api_db_stats();
create or replace function public.api_db_stats(p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'aggRows', s.agg_rows, 'days', s.days,
    'first', case when s.first_ts is null then null
                  else to_char(to_timestamp(s.first_ts) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') end,
    'last',  case when s.last_ts is null then null
                  else to_char(to_timestamp(s.last_ts) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') end,
    'perInverterRows', s.per_inverter_rows,
    'rawSnapshots', 0, 'rawBytesUncompressed', 0, 'rawBytesGzipped', 0)
  from public.q_stats(public.my_plant(p_plant)) s
$$;

-- Health has two callers: the dashboard (per plant) and the external half-hourly
-- check in .github/workflows/health.yml, which asks "is the poller alive at all?"
-- Null plant means the global answer; it does not go through my_plant() because the
-- checker may have no plants of its own.
drop function if exists public.api_health();
create or replace function public.api_health(p_plant bigint default null)
returns jsonb
language sql
stable security definer
set search_path = public, pg_temp
as $$
  with s as (
    select max(ts) as last_ts from public.agg_minute
     where p_plant is null or plant_id = public.my_plant(p_plant)
  )
  select jsonb_build_object(
    'lastTs', s.last_ts,
    'ageSeconds', case when s.last_ts is null then null
                       else extract(epoch from now())::bigint - s.last_ts end,
    'stale', s.last_ts is null
             or (extract(epoch from now())::bigint - s.last_ts) > 900,
    'expectedIntervalSeconds', 60,
    'scope', case when p_plant is null then 'all' else 'plant' end)
  from s
$$;

-- Forecast reads only the single-site irradiance tables; the plant argument is
-- accepted so the frontend can call every api_* the same way and access is asserted.
drop function if exists public.api_forecast();
create or replace function public.api_forecast(p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  k as (select public.forecast_k() as k, public.forecast_k_day() as kd),
  today as (select (now() at time zone 'Africa/Johannesburg')::date as d),
  h as (
    select f.ts, f.gti_wm2, f.cloud_pct,
           lead(f.ts)      over (order by f.ts) as ts2,
           lead(f.gti_wm2) over (order by f.ts) as gti2
      from public.solar_forecast f
     where public.local_day(f.ts) >= (select d from today)
  ),
  day_rows as (
    select public.local_day(ts) as day,
           sum(case when ts2 is not null and ts2 - ts <= 7200
                    then (gti_wm2 + gti2) / 2.0 * (ts2 - ts) / 3600.0 else 0 end) as gti_hours,
           sum(case when ts2 is not null and ts2 - ts <= 7200
                         and ts >= extract(epoch from now())::bigint
                    then (gti_wm2 + gti2) / 2.0 * (ts2 - ts) / 3600.0 else 0 end) as gti_hours_left,
           max(gti_wm2) as peak_gti,
           avg(cloud_pct) filter (where gti_wm2 > 50) as cloud
      from h group by 1
  ),
  days as (
    select jsonb_agg(jsonb_build_object(
             'date', day::text,
             'kwh',  round((gti_hours / 1000.0 * (select kd from k))::numeric, 1),
             'remainingKwh', case when day = (select d from today)
                             then round((gti_hours_left / 1000.0 * (select kd from k))::numeric, 1) end,
             'peakW', round(peak_gti * (select k from k)),
             'cloud', round(cloud::numeric)) order by day) as j
      from day_rows where day < (select d from today) + 3
  ),
  t0 as (select public.day_start_epoch((select d from today)) as t0),
  pts as (
    select jsonb_agg(jsonb_build_object('t', g.t, 'w', round(
             (h.gti_wm2 + (h.gti2 - h.gti_wm2)
               * ((select t0 from t0) + g.t * 60 - h.ts)::double precision
               / nullif(h.ts2 - h.ts, 0)) * (select k from k))) order by g.t) as j
      from generate_series(0, 1435, 5) g(t)
      join h on (select t0 from t0) + g.t * 60 >= h.ts
            and (select t0 from t0) + g.t * 60 <  h.ts2
  )
  select jsonb_build_object(
    'k',         round((select k from k)::numeric, 2),
    'kDay',      round((select kd from k)::numeric, 2),
    'updatedAt', (select max(fetched_at) from public.solar_forecast),
    'calibrated',(select k is not null from public.solar_forecast_cal where id = 1),
    'samples',   (select samples from public.solar_forecast_cal where id = 1),
    'days',      coalesce((select j from days), '[]'::jsonb),
    'points',    coalesce((select j from pts),  '[]'::jsonb))
  from pl
$$;

-- ---------------------------------------------------------------------------
-- Calibration plant + the nightly solar-cal cron
-- ---------------------------------------------------------------------------
-- The forecast/calibration tables are single-site. "The" site is the first plant
-- ever linked — on the existing deployment, the one bootstrapped from env
-- credentials. Resolved at run time so nothing here hardcodes an id.
create or replace function public.calibration_plant()
returns bigint
language sql stable
set search_path = public, pg_temp
as $$ select min(plant_id) from public.plant_users $$;
revoke all on function public.calibration_plant() from public, anon;
grant execute on function public.calibration_plant() to authenticated, service_role;

-- 0011 scheduled `select public.q_recompute_solar_scale();` — a signature that no
-- longer exists. Re-point the job. No-op where pg_cron is absent (local stack).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('sunsynk-solar-cal');
    perform cron.schedule('sunsynk-solar-cal', '40 2 * * *',
      'select public.q_recompute_solar_scale(public.calibration_plant());');
  else
    raise notice 'pg_cron not enabled here - skipping solar-cal reschedule (expected locally)';
  end if;
exception when others then
  raise notice 'solar-cal reschedule skipped: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- api_alerts_due — service_role only; plant is required
-- ---------------------------------------------------------------------------
drop function if exists public.api_alerts_due();
create or replace function public.api_alerts_due(p_plant bigint)
returns table (kind text, key text, level text, title text, body text, value double precision)
language sql
stable security definer
set search_path = public, private, pg_temp
as $$
  with
  now_s as (select extract(epoch from now())::bigint as t),
  loc as (
    select timezone('Africa/Johannesburg', now()) as ts,
           (timezone('Africa/Johannesburg', now()))::date as day,
           extract(hour from timezone('Africa/Johannesburg', now()))::int as hour
  ),
  hour_key as (
    select to_char(date_trunc('hour', timezone('Africa/Johannesburg', now())),
                   'YYYY-MM-DD"T"HH24') as k
  ),
  health as (
    select h.j->>'stale' = 'true' as stale,
           (h.j->>'ageSeconds')::double precision as age_s
      from (select public.api_health(p_plant) as j) h
  ),
  bal as (
    select public.api_balance(p_plant) as j
  ),
  batt_cfg as (
    select coalesce(public.cfg('BATTERY_KWH'), 26.5)       as pack_kwh,
           coalesce(public.cfg('BATTERY_RESERVE_PCT'), 20) as reserve_pct
  ),
  night_win as (
    select
      a.ts,
      a.soc,
      timezone('Africa/Johannesburg', to_timestamp(a.ts)) as lts,
      (select percentile_cont(0.5) within group
                (order by b.batt_w::double precision)
         from public.agg_minute b
        where b.plant_id = p_plant
          and b.ts > a.ts - 3600 and b.ts <= a.ts
          and b.batt_w is not null) as draw_w
      from public.agg_minute a, now_s
     where a.plant_id = p_plant and a.ts > now_s.t - 1800
  ),
  night_calc as (
    select
      w.ts,
      case when extract(hour from w.lts)::int < 6
           then w.lts::date - 1 else w.lts::date end as night_day,
      case
        when extract(hour from w.lts)::int >= 18 then
          extract(epoch from ((w.lts::date + 1) + time '06:00') - w.lts) / 3600.0
        when extract(hour from w.lts)::int < 6 then
          extract(epoch from (w.lts::date + time '06:00') - w.lts) / 3600.0
        else null
      end as hrs_to_sunrise,
      case when w.draw_w < -50
           then greatest(0.0, (coalesce(w.soc, 0) - c.reserve_pct) / 100.0 * c.pack_kwh)
                / (abs(w.draw_w) / 1000.0)
           else null end as hrs_left
      from night_win w, batt_cfg c
  ),
  overnight as (
    select
      (array_agg(night_day order by ts desc))[1] as night_day,
      (array_agg(hrs_left  order by ts desc))[1] as hrs_left,
      count(*) as n,
      bool_and(hrs_left is not null and hrs_left < hrs_to_sunrise) as sustained
      from night_calc
     where hrs_to_sunrise is not null
  ),
  grid_min as (
    select r.ts, public.q_grid_present(p_plant, r.ts) as present
      from (select distinct ts from public.readings, now_s
             where plant_id = p_plant and ts >= now_s.t - 1800) r
  ),
  relay as (
    select (select r.grid_relay_status from public.readings r
             where r.plant_id = p_plant
               and r.ts = (select max(ts) from public.readings where plant_id = p_plant)
               and r.grid_relay_status is not null limit 1) as status
  ),
  grid as (
    select
      (select present from grid_min order by ts desc limit 1) as latest,
      (select count(*) from grid_min, now_s
        where ts >= now_s.t - 180 and present is false) as false_3m,
      (select count(*) from grid_min, now_s
        where ts >= now_s.t - 180 and present is true) as true_3m,
      (select count(*) from grid_min, now_s
        where ts >= now_s.t - 1800 and present is false) as false_30m,
      (select count(*) from grid_min, now_s
        where ts >= now_s.t - 120 and present is false) as false_2m
  ),
  str_latest as (select max(ts) as ts from public.strings where plant_id = p_plant),
  dead_held as (
    select s.sn, s.no
      from public.strings s, loc, now_s
     where s.plant_id = p_plant
       and loc.hour between 11 and 14
       and s.ts >= now_s.t - 900
       and coalesce(s.volt_v, 0) < 1.5
       and coalesce(s.power_w, 0) < 5
       and exists (
         select 1 from public.strings o
          where o.plant_id = p_plant
            and o.ts = s.ts and o.sn = s.sn and o.no is distinct from s.no
            and coalesce(o.power_w, 0) > 200
       )
     group by s.sn, s.no
    having count(*) >= 12
       and exists (
         select 1 from public.strings cur, str_latest
          where cur.plant_id = p_plant
            and cur.ts = str_latest.ts
            and cur.sn = s.sn and cur.no = s.no
            and coalesce(cur.volt_v, 0) < 1.5
            and coalesce(cur.power_w, 0) < 5
       )
  ),
  dead as (
    select
      count(*)::int as n,
      string_agg(
        'string ' || d.no::text || coalesce(' on ' || nullif(m.alias, ''), ''),
        ', ' order by m.alias, d.no
      ) as which
      from dead_held d
      left join private.meta m on m.sn = d.sn
  )
  select 'logger_stale',
         'logger_stale:' || (select k from hour_key),
         'urgent',
         'Solar logger stopped',
         'No data for ' || greatest(1, round(age_s / 60.0))::int || ' minutes',
         age_s
    from health where stale

  union all
  select 'bank_drift',
         'bank_drift:' || (select k from hour_key),
         'urgent',
         'Battery banks drifting',
         coalesce(round((j->>'socSpread')::numeric, 0)::text, '?') || '% apart for 10 minutes',
         (j->>'socSpread')::double precision
    from bal where j->>'status' = 'drifting'

  union all
  select 'batt_hot',
         'batt_hot:' || (select day from loc)::text,
         'urgent',
         'Battery is hot · ' || round((j->>'tempC')::numeric, 0)::text || '°C',
         '',
         (j->>'tempC')::double precision
    from bal where (j->>'tempHot')::boolean is true

  union all
  select 'soc_overnight',
         'soc_overnight:' || night_day::text,
         'urgent',
         'Battery won''t last the night',
         floor(hrs_left)::int || 'h '
            || lpad(round((hrs_left - floor(hrs_left)) * 60)::int::text, 2, '0')
            || 'm left at tonight''s draw',
         hrs_left
    from overnight
   where sustained
     and n >= 25

  union all
  select 'grid_down',
         'grid_down:' || (select k from hour_key),
         'urgent',
         case when (select status from relay) = '1' then 'Grid is off'
              else 'Grid may be off' end,
         case when (select status from relay) = '1'
              then 'No mains voltage while still connected'
              else 'No voltage, but the inverter has also opened the relay — unconfirmed' end,
         null
    from grid
   where latest is false and false_3m >= 3 and true_3m = 0

  union all
  select 'grid_back',
         'grid_back:' || (select k from hour_key),
         'urgent',
         'Grid is back',
         '',
         null
    from grid
   where latest is true
     and false_2m = 0
     and false_30m >= 3

  union all
  select 'string_dead',
         'string_dead:' || (select day from loc)::text,
         'digest',
         case when n = 1 then 'A solar string looks dead'
              else n::text || ' solar strings look dead' end,
         which || ' — no voltage, sibling still producing',
         n::double precision
    from dead
   where n > 0
$$;
revoke all on function public.api_alerts_due(bigint) from public, anon, authenticated;
grant execute on function public.api_alerts_due(bigint) to service_role;

-- ---------------------------------------------------------------------------
-- Grants. Drop-and-create resets EXECUTE to PUBLIC, so every function is re-granted
-- explicitly. Same split as before: q_* helpers that the browser reaches indirectly
-- stay callable by authenticated; the recovery/calibration helpers are service_role.
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  -- authenticated + service_role
  foreach f in array array[
    'api_overview(bigint)', 'api_history(date,bigint)', 'api_balance(bigint)',
    'api_energy(text,bigint)', 'api_history_earliest(bigint)',
    'api_trends_daily(integer,bigint)', 'api_trends_monthly(bigint)', 'api_trends_compare(bigint)',
    'api_trends_potential(date,bigint)', 'api_trends_by_hour(integer,bigint)',
    'api_trends_segments(integer,bigint)', 'api_db_stats(bigint)', 'api_health(bigint)',
    'api_forecast(bigint)',
    'q_day_agg(bigint,date,text)', 'q_grid_present(bigint,bigint)', 'q_day_gap_minutes(bigint,date)',
    'q_recovered_minutes(bigint,date)', 'q_by_hour(bigint,integer)', 'q_segment_power(bigint,integer)',
    'q_stats(bigint)', 'q_cal_samples(bigint)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;

  -- service_role only
  foreach f in array array[
    'q_missing_minutes(bigint,date)', 'q_insert_recovered(bigint,jsonb)',
    'q_grid_feed_scale(bigint)', 'q_forecast_cal_samples(bigint,integer)',
    'q_forecast_cal_days(bigint,integer)', 'q_recompute_solar_scale(bigint)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
