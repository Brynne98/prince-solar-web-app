-- ============================================================================
-- api_overview restated its own copy of the grid-presence test.
--
-- 0015 added q_grid_present(ts) and then, forty lines later, inlined the same
-- `bool_or(grid_volt_v > 100)` into api_overview's gp CTE -- with a comment
-- pointing at the function it was duplicating. Change the threshold in one and
-- the Live tab's grid state silently disagrees with the grid_down / grid_back
-- alerts, which read the function.
--
-- Same statement otherwise; the output is byte-identical.
-- ============================================================================

create or replace function public.api_overview()
returns jsonb
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  with latest as (select max(ts) as ts from public.readings),
  r as (select rd.* from public.readings rd, latest where rd.ts = latest.ts),
  -- per-inverter strings for the same minute
  st as (
    select s.sn, jsonb_agg(jsonb_build_object(
             'id', null, 'no', s.no, 'power', s.power_w,
             'voltage', s.volt_v, 'current', s.current_a, 'today', s.today_kwh)
           order by s.no) as strings
      from public.strings s, latest
     where s.ts = latest.ts group by s.sn
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
               -- signedPower is normalised at ingestion (+ = charging), so direction
               -- is just the sign; no firmware convention leaks out here
               'signedPower', round(r.batt_w),
               'status', case when r.batt_w > 5 then 'charging'
                              when r.batt_w < -5 then 'discharging' else 'idle' end,
               'soc', r.batt_soc, 'voltage', r.batt_voltage_v, 'current', r.batt_current_a,
               'temperature', r.batt_temp_c,   -- raw, incl. junk like -100
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
           -- SunSynk's own list order; rows migrated from SQLite have none yet and
           -- fall back to serial order until the next poll fills it in
           coalesce(m.ord, 9999) as ord
      from r
      left join private.meta m on m.sn = r.sn
      left join st on st.sn = r.sn
  ),
  totals as (
    select sum(round(pv_w)) as pv, sum(round(load_w)) as load,
           sum(round(grid_w)) as grid, sum(round(batt_w)) as batt,
           -- average SOC over inverters with a VALID reading only: a dropped BMS
           -- link reports 0, which would otherwise halve the displayed SOC
           avg(batt_soc) filter (where batt_soc > 0) as soc,
           sum(pv_today_kwh) as today_pv,
           sum(grid_import_today_kwh) as today_imp,
           sum(grid_export_today_kwh) as today_exp
      from inv
  ),
  -- grid presence: mains voltage on ANY inverter, per q_grid_present
  gp as (
    select public.q_grid_present((select ts from latest)) as present
  ),
  -- Grid import/export today integrated from our OWN logger. The per-inverter
  -- counter only populates on the CT-bearing master, so summing snapshots
  -- under-counts by ~half. Same source the day chart uses.
  grid_today as (
    select coalesce(sum(case when grid_w > 0 then grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           coalesce(sum(case when grid_w < 0 then -grid_w * (5.0/60) / 1000 else 0 end), 0) as exp,
           count(*) as n
      from public.q_day_agg((now() at time zone 'Africa/Johannesburg')::date, null)
  ),
  plant as (
    select m.plant_id as id, m.plant_name as name
      from private.meta m where m.plant_id is not null order by m.sn limit 1
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
    'inverters', coalesce((select jsonb_agg(snap order by ord, sn) from inv), '[]'::jsonb))
  from totals t, grid_today g
$$;

revoke all on function public.api_overview() from public, anon;
grant execute on function public.api_overview() to authenticated, service_role;
