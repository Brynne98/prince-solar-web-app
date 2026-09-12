-- ============================================================================
-- 0042 — plant shapes the dashboard had never met (READINESS.md, Stages 3 and 4).
--
--   * battery banks: two inverters on one shared pack read the same BMS, so SoC
--     is the master's, not an average of copies, and there is one bank to drift.
--   * second bank: the API's *2 battery fields, stored and shown when present.
--   * three-phase: L2/L3 grid and output voltages stored; a dropped phase while
--     another is live is reported as phaseDown.
--   * no battery / off-grid: plant_config.has_battery / has_grid, detected from
--     the first day of readings (plant_features_detect), user-overridable. The
--     UI hides what is not there and the alerts skip what cannot fire.
--   * export: tariff_export for feed-in income.
-- ============================================================================

alter table public.plant_config
  add column if not exists battery_banks text not null default 'per-inverter'
    check (battery_banks in ('per-inverter', 'shared')),
  add column if not exists has_battery boolean,
  add column if not exists has_grid boolean,
  add column if not exists features_source text not null default 'default'
    check (features_source in ('default', 'detected', 'user')),
  add column if not exists features_updated_at timestamptz,
  add column if not exists tariff_export double precision not null default 0;

comment on column public.plant_config.has_battery is 'null = not known yet (everything shown); detected from readings, or set by the user.';
comment on column public.plant_config.has_grid is 'null = not known yet (everything shown); false = off-grid: no grid tile, no presence pill, no grid alerts.';

alter table public.readings
  add column if not exists batt2_soc        double precision,
  add column if not exists batt2_voltage_v  double precision,
  add column if not exists batt2_current_a  double precision,
  add column if not exists batt2_power_w    double precision,
  add column if not exists batt2_temp_c     double precision,
  add column if not exists grid_volt_l2_v   double precision,
  add column if not exists grid_volt_l3_v   double precision,
  add column if not exists output_volt_l2_v double precision,
  add column if not exists output_volt_l3_v double precision;

-- ---------------------------------------------------------------------------
-- What this plant has, from what it has reported. Runs from the poller on
-- refresh minutes; never overrides a user's answer.
-- ---------------------------------------------------------------------------
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
begin
  select has_battery, has_grid, features_source into cur from public.plant_config where plant_id = p_plant;
  if cur.features_source = 'user' then
    return jsonb_build_object('plant', p_plant, 'skipped', 'user override');
  end if;
  select count(*),
         bool_or((batt_soc between 1 and 100) or coalesce(batt_voltage_v, 0) > 10),
         bool_or(coalesce(grid_volt_v, 0) > 100 or coalesce(grid_import_today_kwh, 0) > 0
                 or coalesce(grid_export_today_kwh, 0) > 0 or abs(coalesce(grid_w, 0)) > 50)
    into n, hb, hg
    from public.readings
   where plant_id = p_plant and ts > extract(epoch from now())::bigint - 86400 and not carried;
  if n < 30 then
    return jsonb_build_object('plant', p_plant, 'decided', false, 'rows', n);
  end if;
  update public.plant_config
     set has_battery = hb, has_grid = hg, features_source = 'detected', features_updated_at = now()
   where plant_id = p_plant
     and (has_battery is distinct from hb or has_grid is distinct from hg or features_source = 'default');
  return jsonb_build_object('plant', p_plant, 'decided', true, 'hasBattery', hb, 'hasGrid', hg, 'rows', n);
end $$;
revoke all on function public.plant_features_detect(bigint) from public, anon, authenticated;
grant execute on function public.plant_features_detect(bigint) to service_role;

-- A user setting either flag pins both; clearing both hands them back to detection.
create or replace function public.plant_config_features_guard()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and (new.has_battery is distinct from old.has_battery or new.has_grid is distinct from old.has_grid) then
    new.features_source := case when new.has_battery is null and new.has_grid is null then 'default' else 'user' end;
    new.features_updated_at := now();
  end if;
  return new;
end $$;
drop trigger if exists plant_config_features_guard on public.plant_config;
create trigger plant_config_features_guard before update on public.plant_config
  for each row execute function public.plant_config_features_guard();

-- ---------------------------------------------------------------------------
-- plant_cfg: every column the functions and the UI need, in one row.
-- ---------------------------------------------------------------------------
drop function if exists public.plant_cfg(bigint) cascade;
create or replace function public.plant_cfg(p_plant bigint)
returns table (timezone text, currency text, lat double precision, lon double precision,
               system_kwp double precision, tariff_import double precision,
               battery_kwh double precision, battery_reserve_pct double precision,
               panel_tilt double precision, panel_azimuth double precision, geometry_source text,
               tariff_export double precision, battery_banks text, has_battery boolean, has_grid boolean,
               features_source text, batt_positive_means text, batt_sign_source text)
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce(c.timezone, 'Africa/Johannesburg'),
         coalesce(c.currency, 'ZAR'),
         coalesce(c.lat, public.cfg('LAT')), coalesce(c.lon, public.cfg('LON')),
         coalesce(c.system_kwp, public.cfg('SYSTEM_KWP')),
         coalesce(c.tariff_import, 0),
         -- app_config's pack size describes the deployment's own plant only; any
         -- other plant reads null until its owner sets it (the UI then asks).
         coalesce(c.battery_kwh, case when x.id = public.calibration_plant() then public.cfg('BATTERY_KWH') end),
         coalesce(c.battery_reserve_pct, public.cfg('BATTERY_RESERVE_PCT'), 20),
         coalesce(c.panel_tilt, public.cfg('PANEL_TILT'), 15),
         coalesce(c.panel_azimuth, public.cfg('PANEL_AZIMUTH'), 0),
         coalesce(c.geometry_source, 'default'),
         coalesce(c.tariff_export, 0),
         coalesce(c.battery_banks, 'per-inverter'),
         c.has_battery, c.has_grid,
         coalesce(c.features_source, 'default'),
         c.batt_positive_means, coalesce(c.batt_sign_source, 'default')
    from (select p_plant as id) x
    left join public.plant_config c on c.plant_id = x.id
$$;
revoke all on function public.plant_cfg(bigint) from public, anon;
grant execute on function public.plant_cfg(bigint) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- api_overview: 0028's body plus bank2, per-phase voltages, shared-bank SoC,
-- phaseDown and the new config keys.
-- ---------------------------------------------------------------------------
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
    'inverters', coalesce((select jsonb_agg(snap order by ord, sn) from inv), '[]'::jsonb))
  from totals t, grid_today g, cfg c
$$;

-- ---------------------------------------------------------------------------
-- api_balance: 0028's body; a shared pack is one bank.
-- ---------------------------------------------------------------------------
create or replace function public.api_balance(p_plant bigint default null)
returns jsonb language sql stable set search_path = public, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  now_s as (select extract(epoch from now())::bigint as t),
  latest_ts as (select max(ts) as ts from public.readings where plant_id = (select id from pl) and batt_soc is not null),
  -- one shared pack counts as one bank however many inverters read it (0042)
  nbanks as (select case when (select battery_banks from public.plant_config where plant_id = (select id from pl)) = 'shared' then least(1, count(distinct r.sn)) else count(distinct r.sn) end as n
               from public.readings r, latest_ts where r.plant_id = (select id from pl) and r.ts = latest_ts.ts and r.batt_soc between 1 and 100),
  bal as (
    select r.ts, max(r.batt_soc) - min(r.batt_soc) as socspread, max(r.batt_voltage_v) - min(r.batt_voltage_v) as vspread
      from public.readings r, now_s
     where r.plant_id = (select id from pl) and r.ts >= now_s.t - 72 * 3600
       and r.batt_soc is not null and r.batt_soc between 1 and 100
     group by r.ts
    having count(distinct r.sn) >= 2 and (max(r.batt_soc) - min(r.batt_soc)) <= 25
  ),
  last_r as (select * from bal order by ts desc limit 1),
  win as (select count(*) >= 2 and (max(ts) - min(ts)) >= 9 * 60 as have_window, min(socspread) as min_spread from bal, now_s where bal.ts >= now_s.t - 600),
  spreads as (select (select round(socspread * 10) / 10 from last_r) as soc_spread, (select round(vspread * 100) / 100 from last_r) as v_spread),
  st as (
    select case when (select n from nbanks) < 2 then 'single'
                when s.soc_spread is null then 'unknown'
                when not coalesce(w.have_window, false) then 'balanced'
                when w.min_spread >= 5 then 'drifting' when w.min_spread >= 3 then 'watch' else 'balanced' end as status,
           case when (select n from nbanks) < 2 then 'single'
                when s.soc_spread is null then 'unknown'
                when s.soc_spread < 3 then 'balanced' when s.soc_spread < 5 then 'watch' else 'drifting' end as live_band,
           s.soc_spread, s.v_spread
      from spreads s, win w
  ),
  today_lo as (select public.day_start_epoch_tz(public.today_tz((select tz from pz)), (select tz from pz)) as lo),
  health as (
    select (select batt_temp_c from public.readings where plant_id = (select id from pl) and batt_temp_c > 0 and batt_temp_c < 80 order by ts desc limit 1) as temp_c,
           (select coalesce(round(sum(case when soc >= 98 then 1 else 0 end) / 60.0, 1), 0)
              from public.agg_minute, today_lo where plant_id = (select id from pl) and ts >= today_lo.lo and ts < today_lo.lo + 86400) as hrs_full
  )
  select jsonb_build_object(
    'banks', coalesce((select jsonb_agg(jsonb_build_object('sn', r.sn, 'soc', r.batt_soc, 'voltage', r.batt_voltage_v, 'current', r.batt_current_a) order by r.sn)
              from public.readings r, latest_ts where r.plant_id = (select id from pl) and r.ts = latest_ts.ts), '[]'::jsonb),
    'bankCount', (select n from nbanks),
    'socSpread', st.soc_spread, 'vSpread', st.v_spread, 'status', st.status,
    'pending', st.live_band not in ('unknown', 'balanced', 'single') and st.status = 'balanced',
    'max24h', (select round(max(socspread) * 10) / 10 from bal, now_s where bal.ts >= now_s.t - 24 * 3600),
    'max72h', (select round(max(socspread) * 10) / 10 from bal),
    'samples', (select count(*) from bal),
    'tempC', h.temp_c, 'hrsAtFullToday', h.hrs_full,
    'tempHot', h.temp_c is not null and h.temp_c > 35,
    'stale', (select ts from latest_ts) is null or ((select t from now_s) - (select ts from latest_ts)) > 600)
  from st, health h
$$;

-- ---------------------------------------------------------------------------
-- api_alerts_due: the existing body becomes api_alerts_due_raw; the public name
-- filters out alerts about equipment the plant does not have.
-- ---------------------------------------------------------------------------
drop function if exists public.api_alerts_due_raw(bigint);
alter function public.api_alerts_due(bigint) rename to api_alerts_due_raw;
create or replace function public.api_alerts_due(p_plant bigint)
returns table (kind text, key text, level text, title text, body text, value double precision)
language sql stable security definer
set search_path = public, private, pg_temp
as $$
  select a.kind, a.key, a.level, a.title, a.body, a.value
    from public.api_alerts_due_raw(p_plant) a
    left join public.plant_config c on c.plant_id = p_plant
   where not (a.kind in ('soc_overnight', 'bank_drift', 'batt_hot') and c.has_battery is false)
     and not (a.kind in ('grid_down', 'grid_back') and c.has_grid is false)
$$;
revoke all on function public.api_alerts_due_raw(bigint) from public, anon, authenticated;
grant execute on function public.api_alerts_due_raw(bigint) to service_role;
revoke all on function public.api_alerts_due(bigint) from public, anon, authenticated;
grant execute on function public.api_alerts_due(bigint) to service_role;
