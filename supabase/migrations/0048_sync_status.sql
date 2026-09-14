-- ============================================================================
-- 0048 — the overview snapshot says whether history is still being fetched.
--
-- A freshly linked plant takes a day or two of six-hourly recover runs to pull
-- its last 60 days (0044 minute-history bookmark, 0045/0046 inverter-history
-- watermark). Until now the app called those days "No data". api_overview now
-- carries `sync`: whether either walk is pending, the bookmarks, and how many of
-- the last 60 days have a chart, so the header pill can show "Fetching history"
-- with a bar and the day charts can say "still fetching this day". Body is
-- 0042's api_overview plus the `sy` CTE and the `sync` key.
-- ============================================================================
create or replace function public.api_overview(p_plant bigint default null)
returns jsonb language sql stable security definer set search_path = public, private, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  cfg as (select * from public.plant_cfg((select id from pl))),
  latest as (select max(ts) as ts from public.readings where plant_id = (select id from pl)),
  r as (select rd.* from public.readings rd, latest where rd.plant_id = (select id from pl) and rd.ts = latest.ts),
  st as (
    select s.sn, jsonb_agg(jsonb_build_object('id', null, 'no', s.no, 'power', s.power_w, 'voltage', s.volt_v, 'current', s.current_a, 'today', s.today_kwh) order by s.no) as strings
      from public.strings s, latest where s.plant_id = (select id from pl) and s.ts = latest.ts group by s.sn
  ),
  inv as (
    select r.sn,
           jsonb_build_object(
             'sn', r.sn, 'alias', coalesce(m.alias, r.sn), 'model', m.model, 'status', r.status, 'gsn', m.gsn,
             'soft', m.soft_ver, 'hmi', m.hmi_ver, 'commType', m.comm_type,
             'pv', jsonb_build_object('power', round(r.pv_w), 'today', r.pv_today_kwh, 'total', r.pv_total_kwh, 'strings', coalesce(st.strings, '[]'::jsonb)),
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
  gp as (select public.q_grid_present((select id from pl), (select ts from latest)) as present),
  grid_today as (
    select coalesce(sum(case when grid_w > 0 then grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           coalesce(sum(case when grid_w < 0 then -grid_w * (5.0/60) / 1000 else 0 end), 0) as exp,
           count(*) as n
      from public.q_day_agg((select id from pl), public.today_tz((select timezone from cfg)), null)
  ),
  -- Fresh-link sync state (0048): the minute-history bookmark clears when done; the
  -- inverter-history watermark never clears, it parks at today. Progress is days of
  -- the last 60 with any minute row, in the plant's zone — 60 index probes, and only
  -- while something is pending (the pill ignores it otherwise).
  sy as (
    select s.spine, s.inv, s.backfill_next, s.backfill_until, s.temp_next,
           case when s.spine or s.inv then
             (select count(*) from generate_series(0, 59) g(i)
               where exists (select 1 from public.agg_minute a
                              where a.plant_id = (select id from pl)
                                and a.ts >= public.day_start_epoch_tz(s.today - g.i, s.tz)
                                and a.ts <  public.day_start_epoch_tz(s.today - g.i, s.tz) + 86400))
           else 60 end as days
      from (select (pc.backfill_next is not null) as spine,
                   (pc.temp_next is not null and pc.temp_next < public.today_tz(coalesce(c.timezone, 'Africa/Johannesburg'))) as inv,
                   pc.backfill_next, pc.backfill_until, pc.temp_next,
                   public.today_tz(coalesce(c.timezone, 'Africa/Johannesburg')) as today,
                   coalesce(c.timezone, 'Africa/Johannesburg') as tz
              from public.plant_config pc, cfg c where pc.plant_id = (select id from pl)) s
  ),
  plant as (select pu.plant_id as id, pu.plant_name as name from public.plant_users pu
             where pu.plant_id = (select id from pl) and pu.user_id = auth.uid() limit 1)
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
      'forecastAvailable', (select id from pl) = public.calibration_plant()),
    'inverters', coalesce((select jsonb_agg(snap order by ord, sn) from inv), '[]'::jsonb),
    'sync', (select jsonb_build_object(
      'pending', s.spine or s.inv,
      'spinePending', s.spine,
      'invPending', s.inv,
      'backfillNext', s.backfill_next, 'backfillUntil', s.backfill_until, 'tempNext', s.temp_next,
      'days', s.days, 'window', 60)
      from sy s))
  from totals t, grid_today g, cfg c
$$;
