-- SOLAR-555: an inverter SunSynk stops reporting disappears from today's totals.
--
-- The poller leaves an inverter out of a minute when its input has no reading time
-- (SOLAR-296); the plant row is saved as partial and recover refills it. Three readers
-- took their inverter list from the rows at the plant's newest minute, so that inverter
-- vanished: on 538820 (15 Nov 22:16) Made today read 19.2 kWh, the slave alone, not 43.9,
-- and the header and plant menu counted 1 inverter of 1.
--
-- Now each takes the plant's known inverters (private.inverters) that have a row on the
-- newest reading's local day, and each one's own last row of that day:
--   api_overview        day counters and the inverter list from those rows; live power,
--                       battery %, grid present and phase down from rows at the newest
--                       minute only. A silent inverter keeps its own readAt, so the app
--                       marks it offline once that is over 15 min old (READ_FRESH_MS).
--   api_plant_states    inverters = known inverters with a row today; online = in the
--                       newest minute and flagged online.
--   api_trends_compare  the inv list as above; the per-inverter laterals are unchanged.
-- An inverter with no row today (dead since before midnight, or one taken off the plant
-- that private.inverters still holds) is left out, as before.
-- api_balance (TODO app only) is left as it is.
-- Bodies are 0089, 0101 and 0199's otherwise.

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
  v_lo    bigint;  -- start of v_ts's local day
  v_out   jsonb;
begin
  select max(ts) into v_ts from public.readings where plant_id = v_plant and ts > v_floor;
  if v_ts is null then
    -- nothing in 2 days (outage, or a plant that stopped): look further back
    select max(ts) into v_ts from public.readings where plant_id = v_plant;
  end if;
  v_lo := public.day_start_epoch_tz((to_timestamp(v_ts) at time zone public.plant_tz(v_plant))::date, public.plant_tz(v_plant));

  with pl as (select v_plant as id),
  cfg as (select * from public.plant_cfg(v_plant)),
  -- each known inverter's own last row of v_ts's day (SOLAR-555). An inverter the poller
  -- left out of the newest minute (SOLAR-296) keeps its day totals and its readAt; only
  -- the live figures below are limited to rows at v_ts. Bounds are variables, not a join
  -- to a CTE, so each probe opens that day's partition only (sn_ts index).
  r as (
    select x.* from private.inverters i
      cross join lateral (select rd.* from public.readings rd
                           where rd.sn = i.sn and rd.plant_id = v_plant and rd.ts >= v_lo and rd.ts <= v_ts
                           order by rd.ts desc limit 1) x
     where i.plant_id = v_plant
  ),
  st as (
    select s.sn, jsonb_agg(jsonb_build_object('id', null, 'no', s.no, 'power', s.power_w, 'voltage', s.volt_v, 'current', s.current_a, 'today', s.today_kwh) order by s.no) as strings
      from r join public.strings s on s.plant_id = v_plant and s.sn = r.sn and s.ts = r.ts
     where s.ts >= v_lo and s.ts <= v_ts
     group by s.sn
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
           r.ts, r.pv_w, r.load_w, r.grid_w, r.batt_w, r.batt_soc, r.pv_today_kwh, r.grid_import_today_kwh, r.grid_export_today_kwh,
           r.grid_volt_v, r.grid_volt_l2_v, r.grid_volt_l3_v,
           coalesce(m.ord, 9999) as ord
      from r left join private.meta m on m.sn = r.sn left join st on st.sn = r.sn
  ),
  -- live figures from the inverters in the newest minute only; day counters from every row
  totals as (
    select sum(round(pv_w)) filter (where ts = v_ts) as pv, sum(round(load_w)) filter (where ts = v_ts) as load,
           sum(round(grid_w)) filter (where ts = v_ts) as grid, sum(round(batt_w)) filter (where ts = v_ts) as batt,
           -- one shared pack: every inverter reads the same BMS, so take the first (master) rather than averaging copies
           case when (select battery_banks from cfg) = 'shared'
                then (select i.batt_soc from inv i where i.batt_soc > 0 and i.ts = v_ts order by i.ord, i.sn limit 1)
                else avg(batt_soc) filter (where batt_soc > 0 and ts = v_ts) end as soc,
           sum(pv_today_kwh) as today_pv, sum(grid_import_today_kwh) as today_imp, sum(grid_export_today_kwh) as today_exp,
           -- a phase that has dropped while another is live (three-phase only)
           bool_or(grid_volt_v > 100 and least(coalesce(grid_volt_l2_v, 999), coalesce(grid_volt_l3_v, 999)) < 100) filter (where ts = v_ts) as phase_down
      from inv
  ),
  -- q_grid_present's rule on the rows already in r (same plant, same ts); calling
  -- it planned readings again with every partition
  gv as (select grid_volt_v, device_time from r where grid_volt_v is not null and ts = v_ts),
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
    -- the poller's last minute for this plant, as api_health answers it
    'lastTs', (select max(ts) from public.agg_minute where plant_id = v_plant),
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

create or replace function public.api_plant_states()
returns jsonb
language plpgsql
stable security definer
set search_path = public, private, pg_temp
as $$
declare
  -- a variable, not now() in the query, so the planner cuts to the last 2 days
  v_floor bigint := extract(epoch from now())::bigint - 2 * 86400;
  v_out   jsonb := '[]'::jsonb;
  p       record;
  v_ts    bigint;
  v_lo    bigint;
  v_total int;
  v_on    int;
  v_sync  jsonb;
begin
  for p in select pu.plant_id from public.plant_users pu where pu.user_id = auth.uid() order by pu.linked_at, pu.plant_id loop
    select max(ts) into v_ts from public.readings where plant_id = p.plant_id and ts > v_floor;
    if v_ts is null then
      select max(ts) into v_ts from public.readings where plant_id = p.plant_id;
    end if;
    -- known inverters with a row on v_ts's day (SOLAR-555); online = in the newest minute
    -- and flagged online. One sn_ts probe per inverter.
    v_lo := public.day_start_epoch_tz((to_timestamp(v_ts) at time zone public.plant_tz(p.plant_id))::date, public.plant_tz(p.plant_id));
    select count(*), count(*) filter (where x.ts = v_ts and x.status::text in ('1', 'online', 'true'))
      into v_total, v_on
      from private.inverters i
      cross join lateral (select rd.ts, rd.status from public.readings rd
                           where rd.sn = i.sn and rd.plant_id = p.plant_id and rd.ts >= v_lo and rd.ts <= v_ts
                           order by rd.ts desc limit 1) x
     where i.plant_id = p.plant_id;

    select jsonb_build_object(
             'pending', s.spine or s.inv, 'spinePending', s.spine, 'invPending', s.inv,
             'backfillNext', s.backfill_next, 'backfillUntil', s.backfill_until, 'tempNext', s.temp_next,
             'days', case when s.spine or s.inv then
               (select count(*) from generate_series(0, 59) g(i)
                 where exists (select 1 from public.agg_minute a
                                where a.plant_id = p.plant_id
                                  and a.ts >= public.day_start_epoch_tz(s.today - g.i, s.tz)
                                  and a.ts <  public.day_start_epoch_tz(s.today - g.i, s.tz) + 86400)
                    or exists (select 1 from public.agg_5m f
                                where f.plant_id = p.plant_id
                                  and f.ts >= public.day_start_epoch_tz(s.today - g.i, s.tz)
                                  and f.ts <  public.day_start_epoch_tz(s.today - g.i, s.tz) + 86400))
               else 60 end,
             'window', 60)
      into v_sync
      from (select (pc.backfill_next is not null) as spine,
                   (pc.temp_next is not null and pc.temp_next < public.today_tz(coalesce(pc.timezone, 'Africa/Johannesburg'))) as inv,
                   pc.backfill_next, pc.backfill_until, pc.temp_next,
                   public.today_tz(coalesce(pc.timezone, 'Africa/Johannesburg')) as today,
                   coalesce(pc.timezone, 'Africa/Johannesburg') as tz
              from public.plant_config pc where pc.plant_id = p.plant_id) s;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', p.plant_id, 'lastTs', v_ts, 'inverters', v_total, 'online', v_on, 'sync', v_sync));
  end loop;
  return v_out;
end $$;
revoke all on function public.api_plant_states() from public, anon;
grant execute on function public.api_plant_states() to authenticated, service_role;

create or replace function public.api_trends_compare(p_plant bigint default null)
returns jsonb
language sql
stable
security definer
set search_path to public, pg_temp
as $fn$
  with pl as (select public.my_plant(p_plant) as id),
  tz as (select public.plant_tz((select id from pl)) as tz, public.my_read_from((select id from pl)) as rf),
  t as (select public.today_tz((select tz from tz)) as d),
  b as (
    select d,
           date_trunc('week', d)::date  as week_start,
           date_trunc('month', d)::date as month_start,
           date_trunc('year', d)::date  as year_start
      from t
  ),
  -- same day number last month, null when last month has no such day
  lastm as (
    select g::date as cur,
           case when extract(day from (date_trunc('month', g) - interval '1 month' + (extract(day from g)::int - 1) * interval '1 day'))::int
                     = extract(day from g)::int
                then (date_trunc('month', g) - interval '1 month' + (extract(day from g)::int - 1) * interval '1 day')::date end as prev
      from b, generate_series(b.month_start, b.d, interval '1 day') g
  ),
  -- finished current-slice days with the previous-period day each is paired to
  pairs as (
    select 'week' as k, g::date as cur, (g - interval '7 days')::date as prev
      from b, generate_series(b.week_start, b.d - 1, interval '1 day') g
    union all
    select 'month', cur, prev from lastm, b where cur < b.d
    union all
    -- same date last year; 29 Feb pairs with nothing
    select 'year', g::date,
           case when (g - interval '1 year') + interval '1 year' = g then (g - interval '1 year')::date end
      from b, generate_series(b.year_start, b.d - 1, interval '1 day') g
  ),
  span as (
    select min(least(cur, coalesce(prev, cur))) as lo,
           max(greatest(cur, coalesce(prev, cur))) as hi
      from pairs
  ),
  e as (select * from public._plant_day_energy((select id from pl), (select lo from span), (select hi from span))),
  matched as (
    select p.k, p.cur, p.prev,
           c.pv_kwh as c_pv, c.load_kwh as c_load, c.imp_kwh as c_imp,
           v.pv_kwh as p_pv, v.load_kwh as p_load, v.imp_kwh as p_imp
      from pairs p
      join e c on c.period = p.cur
      join e v on v.period = p.prev
  ),
  -- every period gets a row, even on its first day when no finished day pairs yet
  spans as (
    select ks.k, count(p.cur) as span
      from (values ('week'), ('month'), ('year')) ks(k) left join pairs p on p.k = ks.k
     group by ks.k
  ),
  sums as (
    select s.k,
           jsonb_build_object(
             'cur',  jsonb_build_object('pv', coalesce(round(sum(m.c_pv)::numeric, 1), 0), 'load', coalesce(round(sum(m.c_load)::numeric, 1), 0), 'imp', coalesce(round(sum(m.c_imp)::numeric, 1), 0)),
             'prev', jsonb_build_object('pv', coalesce(round(sum(m.p_pv)::numeric, 1), 0), 'load', coalesce(round(sum(m.p_load)::numeric, 1), 0), 'imp', coalesce(round(sum(m.p_imp)::numeric, 1), 0)),
             'days', count(m.cur),
             'span', s.span) as v
      from spans s left join matched m on m.k = s.k
     group by s.k, s.span
  ),
  -- ---- today so far, and the day it pairs with up to the same time ----
  tlo as (select public.day_start_epoch_tz(b.d, (select tz from tz)) as lo from b),
  -- today's latest poll, the one the tiles show; it must be today's
  latest as (
    select r.ts from public.readings r, tlo
     where r.plant_id = (select id from pl) and r.ts >= tlo.lo
     order by r.ts desc limit 1
  ),
  -- today's latest poll as a local clock time; each matching day is read at that clock time
  el as (select (to_timestamp(latest.ts) at time zone (select tz from tz))::time as t from latest),
  tpairs as (
    select 'today' as k, (b.d - 1) as prev from b
    union all select 'week', (b.d - 7) from b
    union all select 'month', (select prev from lastm, b where lastm.cur = b.d)
    union all select 'year', case when (b.d - interval '1 year') + interval '1 year' = b.d then (b.d - interval '1 year')::date end from b
  ),
  tc as (
    select p.k, p.prev, x.lo, extract(epoch from ((p.prev + el.t) at time zone (select tz from tz)))::bigint as cut
      from tpairs p, el,
           lateral (select public.day_start_epoch_tz(p.prev, (select tz from tz)) as lo) x
     where p.prev is not null
  ),
  -- each known inverter with a row today (SOLAR-555; was: those in today's latest poll,
  -- which drops one the poller left out): its last good reading on the matching day at or
  -- before the moment, from readings, else the 5-minute history (counters as at the
  -- bucket's end). One index probe per inverter per pair.
  inv as (
    select i.sn from private.inverters i, tlo
     where i.plant_id = (select id from pl)
       and exists (select 1 from public.readings r
                    where r.sn = i.sn and r.plant_id = i.plant_id and r.ts >= tlo.lo and r.ts <= (select ts from latest))
  ),
  per as (
    select tc.k, i.sn,
           coalesce(x.pv, y.pv) as pv, coalesce(x.load, y.load) as load, coalesce(x.imp, y.imp) as imp,
           (x.ts is not null or y.ts is not null) as found
      from tc cross join inv i
      left join lateral (
        select r.ts, r.pv_today_kwh as pv, r.load_today_kwh as load, r.grid_import_today_kwh as imp
          from public.readings r
         where r.sn = i.sn and r.plant_id = (select id from pl)
           and r.ts >= tc.lo and r.ts <= tc.cut and r.ts >= (select rf from tz) and r.device_time is not null
         order by r.ts desc limit 1) x on true
      left join lateral (
        select f.ts, f.pv_today_kwh as pv, f.load_today_kwh as load, f.grid_import_today_kwh as imp
          from public.readings_5m f
         where x.ts is null
           and f.plant_id = (select id from pl) and f.sn = i.sn
           and f.ts >= tc.lo and f.ts <= tc.cut - 300 and f.ts >= (select rf from tz) and f.pv_today_kwh is not null
         order by f.ts desc limit 1) y on true
  ),
  ctr as (
    select k, sum(pv) as pv, sum(load) as load, sum(imp) as imp
      from per group by k
    having bool_and(found)
  ),
  -- the matching day from the minute history, 5-minute power summed to kWh: the grid
  -- figure always, solar and home when no inverter counters cover that day (SOLAR-508)
  ig as (
    select tc.k,
           coalesce(sum(case when a.grid_w > 0 then a.grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           coalesce(sum(greatest(a.pv_w, 0) * (5.0/60) / 1000), 0) as pv,
           coalesce(sum(greatest(a.load_w, 0) * (5.0/60) / 1000), 0) as load,
           count(a.hm) as n
      from tc left join lateral (
        select q.hm, q.grid_w, q.pv_w, q.load_w from public.q_day_agg((select id from pl), tc.prev, null) q
         where q.hm <= to_char(public.local_ts_tz(tc.cut, (select tz from tz)), 'HH24:MI')) a on true
     group by tc.k
  ),
  -- counters first; a plant just imported has none for yesterday, only the minute history
  nowv as (
    select g.k, jsonb_build_object(
             'pv',   coalesce(round(coalesce(c.pv, g.pv)::numeric, 1), 0),
             'load', coalesce(round(coalesce(c.load, g.load)::numeric, 1), 0),
             'imp',  coalesce(round((case when g.n > 5 then g.imp else c.imp end)::numeric, 1), 0)) as v
      from ig g left join ctr c on c.k = g.k
     where c.k is not null or g.n > 5
  )
  select coalesce((select jsonb_object_agg(s.k, s.v || jsonb_build_object('now', (select v from nowv where nowv.k = s.k))) from sums s), '{}'::jsonb)
         || jsonb_build_object('today', jsonb_build_object(
              'cur',  jsonb_build_object('pv', 0, 'load', 0, 'imp', 0),
              'prev', coalesce((select v from nowv where k = 'today'), jsonb_build_object('pv', 0, 'load', 0, 'imp', 0)),
              'days', case when exists (select 1 from nowv where k = 'today') then 1 else 0 end,
              'span', 1))
$fn$;

notify pgrst, 'reload schema';
