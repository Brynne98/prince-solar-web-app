-- ============================================================================
-- 0088 — cheaper hot database calls (SOLAR-141).
--
-- PostgREST drops a connection after 30 s idle, so the once-a-minute calls
-- mostly land on a fresh connection. A fresh connection loads catalog entries
-- for every partition a query names, and readings and strings had 46 day
-- partitions each (31 kept, 14 empty future days). A SQL function plans its
-- queries with the plant and time as parameters, so nothing was cut at plan
-- time: api_overview touched ~14,000 buffers per call, nearly all planning.
--
-- 1. Future partitions: 3 days ahead, not 14. Empty ones past that are dropped.
-- 2. api_overview and inverters_cached become plpgsql. The newest reading time
--    and the 24 h floor are variables, so each query is planned with a fixed
--    value and only the partitions it needs are opened.
-- 3. plant_features_detect: once decided, rechecks once a day, not every 5 min.
-- 4. api_plant_days: the day count the app reads at start, in place of
--    api_db_stats + api_trends_by_hour (only stats.days was used).
-- ============================================================================

-- ── 1. partitions: 3 days ahead ─────────────────────────────────────────────
create or replace function private.ensure_partitions(p_days_ahead integer default 3)
returns integer
language plpgsql
set search_path = pg_temp
as $$
declare t text; d date; made int := 0;
begin
  foreach t in array array['readings', 'strings'] loop
    for d in select generate_series((now() at time zone 'UTC')::date::timestamp,
                                    ((now() at time zone 'UTC')::date + p_days_ahead)::timestamp, interval '1 day')::date loop
      if private.ensure_day_partition(t, d) then made := made + 1; end if;
    end loop;
  end loop;
  return made;
end $$;

-- Same as 0081 except the closing ensure_partitions() now takes its default,
-- so the window is set in one place.
create or replace procedure private.rollup_old_days(p_days integer default 61)
language plpgsql
as $$
declare
  cutoff bigint := extract(epoch from ((now() at time zone 'UTC')::date - p_days)::timestamp at time zone 'UTC')::bigint;
  started timestamptz := clock_timestamp();
  c record; n bigint; made bigint; r jsonb;
begin
  for c in
    select p.relname as parent, ch.relname as name,
           private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'FROM') as lo,
           private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'TO')   as hi
      from pg_inherits i
      join pg_class ch on ch.oid = i.inhrelid
      join pg_class p  on p.oid  = i.inhparent
     where i.inhparent in ('public.readings'::regclass, 'public.strings'::regclass)
     order by 3, 1
  loop
    if c.hi - c.lo > 86400 then
      -- a split copies up to a month; leave the rest for tomorrow's run
      if clock_timestamp() - started > interval '60 seconds' then
        raise notice 'rollup_old_days: stopping before %, out of time', c.name;
        exit;
      end if;
      r := private.split_partition(c.parent, c.name, cutoff);
      raise notice 'rollup_old_days: %', r;
    elsif c.hi <= cutoff then
      execute format('select count(*) from public.%I', c.name) into n;
      made := private.rollup_partition(c.parent, c.name);
      execute format('drop table public.%I', c.name);
      insert into private.partitions_dropped (partition_name, upper_bound, rows_dropped)
      values (c.name, to_timestamp(c.hi), n)
      on conflict (partition_name) do update
        set dropped_at = now(), upper_bound = excluded.upper_bound, rows_dropped = excluded.rows_dropped;
    else
      continue;
    end if;
    commit;
  end loop;
  -- the split made day partitions for its own month only
  perform private.ensure_partitions();
  commit;
end $$;

-- Empty day partitions from day 4 on go; a row in one stops the migration.
do $$
declare
  c record; n bigint;
  cut bigint := extract(epoch from ((now() at time zone 'UTC')::date + 4)::timestamp at time zone 'UTC')::bigint;
begin
  for c in
    select ch.relname as name
      from pg_inherits i join pg_class ch on ch.oid = i.inhrelid
     where i.inhparent in ('public.readings'::regclass, 'public.strings'::regclass)
       and private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'FROM') >= cut
  loop
    execute format('select count(*) from public.%I', c.name) into n;
    if n > 0 then raise exception 'future partition % holds % rows', c.name, n; end if;
    execute format('drop table public.%I', c.name);
  end loop;
end $$;

select private.ensure_partitions();

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping jobs (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'ensure-partitions') then
    perform cron.unschedule('ensure-partitions');
  end if;
  perform cron.schedule('ensure-partitions', '0 3 * * *', 'select private.ensure_partitions()');
end $$;

-- ── 2a. api_overview: plpgsql, newest time fixed before the main query ──────
create or replace function public.api_overview(p_plant bigint default null)
returns jsonb
language plpgsql
stable security definer
set search_path = public, private, pg_temp
as $$
declare
  v_plant bigint := public.my_plant(p_plant);
  -- a variable, not now() in the query, so the planner cuts to the last 2 days
  v_floor bigint := extract(epoch from now())::bigint - 2 * 86400;
  v_ts    bigint;
  v_out   jsonb;
begin
  select max(ts) into v_ts from public.readings where plant_id = v_plant and ts > v_floor;
  if v_ts is null then
    -- nothing in 2 days (outage, or a plant that stopped): look further back
    select max(ts) into v_ts from public.readings where plant_id = v_plant;
  end if;

  with pl as (select v_plant as id),
  cfg as (select * from public.plant_cfg(v_plant)),
  -- rd.ts = v_ts, not a join to a CTE: a fixed value opens one partition
  r as (select rd.* from public.readings rd where rd.plant_id = v_plant and rd.ts = v_ts),
  st as (
    select s.sn, jsonb_agg(jsonb_build_object('id', null, 'no', s.no, 'power', s.power_w, 'voltage', s.volt_v, 'current', s.current_a, 'today', s.today_kwh) order by s.no) as strings
      from public.strings s where s.plant_id = v_plant and s.ts = v_ts group by s.sn
  ),
  inv as (
    select r.sn,
           jsonb_build_object(
             'sn', r.sn, 'alias', coalesce(m.alias, r.sn), 'model', m.model, 'status', r.status, 'gsn', m.gsn,
             'soft', m.soft_ver, 'hmi', m.hmi_ver, 'commType', m.comm_type,
             -- when the inverter took this reading, epoch seconds; a 5-minute logger can be minutes behind (0075)
             -- guarded: one malformed device_time must not take the whole snapshot down with a cast error
             'readAt', case when r.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
                         then extract(epoch from (r.device_time::timestamp at time zone public.plant_tz(v_plant)))::bigint end,
             'pv', jsonb_build_object('power', round(r.pv_w), 'today', r.pv_today_kwh, 'total', r.pv_total_kwh, 'strings', coalesce(st.strings, '[]'::jsonb),
                     -- inputs the inverter reports, wired or not (0061); the page shows the rest as unused
                     'stringSlots', m.string_slots),
             'battery', jsonb_build_object(
               'power', round(abs(r.batt_w)), 'signedPower', round(r.batt_w),
               'status', case when r.batt_w > 5 then 'charging' when r.batt_w < -5 then 'discharging' else 'idle' end,
               'soc', r.batt_soc, 'voltage', r.batt_voltage_v, 'current', r.batt_current_a, 'temperature', r.batt_temp_c,
               'capacity', m.capacity_ah, 'numberOfBatteries', m.number_of_batteries,
               'todayCharged', r.batt_chg_today_kwh, 'todayDischarged', r.batt_dischg_today_kwh,
               'totalCharged', r.batt_chg_total_kwh, 'totalDischarged', r.batt_dischg_total_kwh,
               -- second bank (the API's *2 fields), only when the firmware reports one (0042)
               'bank2', case when r.batt2_soc is not null then jsonb_build_object(
                 'soc', r.batt2_soc, 'voltage', r.batt2_voltage_v, 'current', r.batt2_current_a,
                 'power', r.batt2_power_w, 'temperature', r.batt2_temp_c) end),
             'grid', jsonb_build_object(
               'power', round(r.grid_w), 'direction', case when r.grid_w >= 0 then 'importing' else 'exporting' end,
               'todayImport', r.grid_import_today_kwh, 'todayExport', r.grid_export_today_kwh,
               'totalImport', r.grid_import_total_kwh, 'totalExport', r.grid_export_total_kwh,
               'frequency', r.grid_freq_hz, 'powerFactor', r.grid_pf,
               'voltage', r.grid_volt_v, 'relay', r.grid_relay_status,
               -- one entry per phase this inverter reports (L1 [, L2, L3])
               'voltages', (select jsonb_agg(v) from unnest(array[r.grid_volt_v, r.grid_volt_l2_v, r.grid_volt_l3_v]) v where v is not null)),
             'load', jsonb_build_object('power', round(r.load_w), 'today', r.load_today_kwh, 'total', r.load_total_kwh, 'frequency', r.load_freq_hz),
             'output', jsonb_build_object('power', round(r.output_w), 'voltage', r.output_volt_v, 'frequency', r.output_freq_hz,
               'voltages', (select jsonb_agg(v) from unnest(array[r.output_volt_v, r.output_volt_l2_v, r.output_volt_l3_v]) v where v is not null))) as snap,
           r.pv_w, r.load_w, r.grid_w, r.batt_w, r.batt_soc, r.pv_today_kwh, r.grid_import_today_kwh, r.grid_export_today_kwh,
           r.grid_volt_v, r.grid_volt_l2_v, r.grid_volt_l3_v,
           coalesce(m.ord, 9999) as ord
      from r left join private.meta m on m.sn = r.sn left join st on st.sn = r.sn
  ),
  totals as (
    select sum(round(pv_w)) as pv, sum(round(load_w)) as load, sum(round(grid_w)) as grid, sum(round(batt_w)) as batt,
           -- one shared pack: every inverter reads the same BMS, so take the first (master) rather than averaging copies
           case when (select battery_banks from cfg) = 'shared'
                then (select i.batt_soc from inv i where i.batt_soc > 0 order by i.ord, i.sn limit 1)
                else avg(batt_soc) filter (where batt_soc > 0) end as soc,
           sum(pv_today_kwh) as today_pv, sum(grid_import_today_kwh) as today_imp, sum(grid_export_today_kwh) as today_exp,
           -- a phase that has dropped while another is live (three-phase only)
           bool_or(grid_volt_v > 100 and least(coalesce(grid_volt_l2_v, 999), coalesce(grid_volt_l3_v, 999)) < 100) as phase_down
      from inv
  ),
  -- q_grid_present's rule on the rows already in r (same plant, same ts); calling
  -- it planned readings again with every partition
  gv as (select grid_volt_v, device_time from r where grid_volt_v is not null),
  gp as (
    select case when not exists (select 1 from gv) then null
                else (select bool_or(v.grid_volt_v > 100) from gv v
                       where v.device_time is not distinct from (select max(device_time) from gv)) end as present
  ),
  grid_today as (
    select coalesce(sum(case when grid_w > 0 then grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           coalesce(sum(case when grid_w < 0 then -grid_w * (5.0/60) / 1000 else 0 end), 0) as exp,
           count(*) as n
      from public.q_day_agg(v_plant, public.today_tz((select timezone from cfg)), null)
  ),
  -- Fresh-link sync state (0048): the minute-history bookmark clears when done; the
  -- inverter-history watermark never clears, it parks at today. Progress is days of
  -- the last 60 with any minute or 5-minute row, in the plant's zone — 60 index probes, and only
  -- while something is pending (the pill ignores it otherwise).
  sy as (
    select s.spine, s.inv, s.backfill_next, s.backfill_until, s.temp_next,
           case when s.spine or s.inv then
             (select count(*) from generate_series(0, 59) g(i)
               where exists (select 1 from public.agg_minute a
                              where a.plant_id = v_plant
                                and a.ts >= public.day_start_epoch_tz(s.today - g.i, s.tz)
                                and a.ts <  public.day_start_epoch_tz(s.today - g.i, s.tz) + 86400)
                  -- past 31 days a backfilled day lives in agg_5m (0082)
                  or exists (select 1 from public.agg_5m f
                              where f.plant_id = v_plant
                                and f.ts >= public.day_start_epoch_tz(s.today - g.i, s.tz)
                                and f.ts <  public.day_start_epoch_tz(s.today - g.i, s.tz) + 86400))
           else 60 end as days
      from (select (pc.backfill_next is not null) as spine,
                   (pc.temp_next is not null and pc.temp_next < public.today_tz(coalesce(c.timezone, 'Africa/Johannesburg'))) as inv,
                   pc.backfill_next, pc.backfill_until, pc.temp_next,
                   public.today_tz(coalesce(c.timezone, 'Africa/Johannesburg')) as today,
                   coalesce(c.timezone, 'Africa/Johannesburg') as tz
              from public.plant_config pc, cfg c where pc.plant_id = v_plant) s
  ),
  plant as (select pu.plant_id as id, pu.plant_name as name from public.plant_users pu
             where pu.plant_id = v_plant and pu.user_id = auth.uid() limit 1)
  select jsonb_build_object(
    'generatedAt', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'plant', jsonb_build_object('id', (select id from plant), 'name', coalesce((select name from plant), 'My plant')),
    'totals', jsonb_build_object(
      'pv', t.pv, 'load', t.load, 'grid', t.grid,
      'gridDirection', case when t.grid >= 0 then 'importing' else 'exporting' end,
      'batteryPower', abs(t.batt),
      'batteryDirection', case when abs(t.batt) <= 5 then 'idle' when t.batt > 0 then 'charging' else 'discharging' end,
      'soc', case when t.soc is null then null else round(t.soc) end,
      'todayPv', round(t.today_pv::numeric, 2),
      'todayGridImport', round((case when g.n > 5 then g.imp else t.today_imp end)::numeric, 2),
      'todayGridExport', round((case when g.n > 5 then g.exp else t.today_exp end)::numeric, 2),
      'gridPresent', (select present from gp),
      'phaseDown', coalesce(t.phase_down, false)),
    'config', jsonb_build_object(
      'battCapacity', c.battery_kwh, 'reserve', c.battery_reserve_pct,
      'currency', c.currency, 'timezone', c.timezone, 'tariffImport', c.tariff_import, 'tariffExport', c.tariff_export,
      'systemKwp', c.system_kwp, 'panelTilt', c.panel_tilt, 'panelAzimuth', c.panel_azimuth,
      'geometrySource', c.geometry_source,
      'batteryBanks', c.battery_banks, 'hasBattery', c.has_battery, 'hasGrid', c.has_grid, 'featuresSource', c.features_source,
      'battPositiveMeans', c.batt_positive_means, 'battSignSource', c.batt_sign_source,
      'forecastAvailable', v_plant = public.calibration_plant()),
    'inverters', coalesce((select jsonb_agg(snap order by ord, sn) from inv), '[]'::jsonb),
    'sync', (select jsonb_build_object(
      'pending', s.spine or s.inv,
      'spinePending', s.spine,
      'invPending', s.inv,
      'backfillNext', s.backfill_next, 'backfillUntil', s.backfill_until, 'tempNext', s.temp_next,
      'days', s.days, 'window', 60)
      from sy s))
    into v_out
  from totals t, grid_today g, cfg c;
  return v_out;
end $$;

-- ── 2b. inverters_cached: plpgsql, 24 h floor as a variable ─────────────────
create or replace function public.inverters_cached(p_account uuid)
returns table(sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text, gsn text, comm_type text, plant_name text, ord integer, status integer, last_reading jsonb, carried_run integer)
language plpgsql
security definer
set search_path = private, pg_temp
as $$
#variable_conflict use_column
declare
  -- a variable, not now() in the query, so the planner opens 2 partitions, not all
  v_floor bigint := extract(epoch from now())::bigint - 86400;
begin
  return query
  select i.sn, i.plant_id, m.alias, m.model, m.soft_ver, m.hmi_ver,
         m.gsn, m.comm_type, m.plant_name, m.ord, m.status,
         lr.row as last_reading,
         coalesce(cr.n, 0)::integer as carried_run
    from private.inverters i
    left join private.meta m on m.sn = i.sn
    left join lateral (
      select to_jsonb(r) as row
        from public.readings r
       where r.sn = i.sn and r.ts > v_floor
       order by r.ts desc
       limit 1) lr on true
    left join lateral (
      select count(*) as n
        from public.readings r
       where r.sn = i.sn and r.ts > v_floor
         and r.ts > coalesce((select max(r2.ts) from public.readings r2
                               where r2.sn = i.sn and r2.ts > v_floor and not r2.carried), 0)) cr on true
   where i.account_id = p_account
   order by coalesce(m.ord, 9999), i.sn;
end $$;

-- ── 3. plant_features_detect: once a day after the first decision ───────────
alter table public.plant_config add column if not exists features_checked_at timestamptz;

create or replace function public.plant_features_detect(p_plant bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  cur record;
  hb boolean;
  hg boolean;
  n  bigint;
  v_floor bigint := extract(epoch from now())::bigint - 86400;
begin
  select has_battery, has_grid, features_source, features_checked_at into cur from public.plant_config where plant_id = p_plant;
  if cur.features_source = 'user' then
    return jsonb_build_object('plant', p_plant, 'skipped', 'user override');
  end if;
  -- battery and grid rarely change: once decided, a day between checks
  if cur.features_source = 'detected' and cur.features_checked_at > now() - interval '1 day' then
    return jsonb_build_object('plant', p_plant, 'skipped', 'checked today');
  end if;
  select count(*),
         bool_or((batt_soc between 1 and 100) or coalesce(batt_voltage_v, 0) > 10),
         bool_or(coalesce(grid_volt_v, 0) > 100 or coalesce(grid_import_today_kwh, 0) > 0
                 or coalesce(grid_export_today_kwh, 0) > 0 or abs(coalesce(grid_w, 0)) > 50)
    into n, hb, hg
    from public.readings
   where plant_id = p_plant and ts > v_floor and not carried;
  if n < 30 then
    return jsonb_build_object('plant', p_plant, 'decided', false, 'rows', n);
  end if;
  update public.plant_config
     set has_battery = hb, has_grid = hg, features_source = 'detected', features_updated_at = now()
   where plant_id = p_plant
     and (has_battery is distinct from hb or has_grid is distinct from hg or features_source = 'default');
  update public.plant_config set features_checked_at = now() where plant_id = p_plant;
  return jsonb_build_object('plant', p_plant, 'decided', true, 'hasBattery', hb, 'hasGrid', hg, 'rows', n);
end $$;

-- ── 4. api_plant_days: days with data, for the empty-state text ─────────────
-- Days of the last 61 (today included) with any minute or 5-minute row, in the
-- plant's zone; 61 when anything older exists. The app only tells "N days so
-- far" apart below 60, so the cap costs nothing and keeps this at ~124 index
-- probes however long the history.
create or replace function public.api_plant_days(p_plant bigint default null)
returns jsonb
language plpgsql
stable security definer
set search_path = public, pg_temp
as $$
declare
  -- plant and day bounds as variables: planned with fixed values, the
  -- (plant_id, ts) keys are used rather than a walk of the ts index
  v_plant bigint := public.my_plant(p_plant);
  v_tz    text   := public.plant_tz(v_plant);
  v_today date   := public.today_tz(v_tz);
  v_lo    bigint := public.day_start_epoch_tz(v_today - 60, v_tz);
  v_days  bigint;
begin
  if exists (select 1 from public.agg_minute where plant_id = v_plant and ts < v_lo)
     or exists (select 1 from public.agg_5m where plant_id = v_plant and ts < v_lo) then
    return jsonb_build_object('days', 61);
  end if;
  select count(*) into v_days
    from generate_series(0, 60) g(i)
   where exists (select 1 from public.agg_minute a
                  where a.plant_id = v_plant
                    and a.ts >= public.day_start_epoch_tz(v_today - g.i, v_tz)
                    and a.ts <  public.day_start_epoch_tz(v_today - g.i, v_tz) + 86400)
      or exists (select 1 from public.agg_5m f
                  where f.plant_id = v_plant
                    and f.ts >= public.day_start_epoch_tz(v_today - g.i, v_tz)
                    and f.ts <  public.day_start_epoch_tz(v_today - g.i, v_tz) + 86400);
  return jsonb_build_object('days', v_days);
end $$;

revoke execute on function public.api_plant_days(bigint) from public, anon;
grant execute on function public.api_plant_days(bigint) to authenticated, service_role;
