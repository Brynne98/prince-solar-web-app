-- ============================================================================
-- 0248 — a new day's first rows (SOLAR-648).
--
-- Until an inverter's first upload after the plant's midnight its "today" counters are
-- still yesterday's: carried rows copy them and SunSynk serves yesterday's battery and
-- grid counters. On 24 Nov 538820's Live page compared today with yesterday at 00:01,
-- whose row held the slave's 11.4 kWh, and read Home −100%. The poller now writes 0
-- (poll/newday.mts); this migration
--   1. rolls minutes into 5-minute buckets keeping a real 0 (the last non-null value; it
--      kept the last non-zero, so a midnight bucket kept yesterday's total over 0s);
--   2. api_trends_compare reads an upload dated before the matching day as 0 so far;
--   3. repairs what is stored: minute rows uploaded before their own day (135 rows on
--      2 plants, 23 Oct–23 Nov), and 5-minute buckets in a day's first 15 minutes whose
--      today counter is above a later bucket's that day (of 369, counted 24 Nov: battery
--      charged 107, discharged 117, grid import 3; Home and solar none).
-- Lifetime counters keep the non-zero rule: a 0 there is a bad read, not a value.
-- ============================================================================

create or replace function private.rollup_partition(p_parent text, p_child text)
returns bigint
language plpgsql
set search_path = public, pg_temp
as $$
declare n bigint;
begin
  if p_parent = 'readings' then
    execute format($q$
      insert into public.readings_5m (plant_id, sn, ts, n, n_fresh, n_carried, status_last, status_kinds, relay_last, relay_open_min, grid_off_min, pv_w_avg, pv_w_min, pv_w_max, batt_w_avg, batt_w_min, batt_w_max, batt_power_w_avg, batt_power_w_min, batt_power_w_max, grid_w_avg, grid_w_min, grid_w_max, load_w_avg, load_w_min, load_w_max, output_w_avg, output_w_min, output_w_max, batt2_power_w_avg, batt2_power_w_min, batt2_power_w_max, batt_current_a_avg, batt_current_a_min, batt_current_a_max, batt2_current_a_avg, batt2_current_a_min, batt2_current_a_max, batt_voltage_v_avg, batt_voltage_v_min, batt_voltage_v_max, batt2_voltage_v_avg, batt2_voltage_v_min, batt2_voltage_v_max, grid_volt_v_avg, grid_volt_v_min, grid_volt_v_max, grid_volt_l2_v_avg, grid_volt_l2_v_min, grid_volt_l2_v_max, grid_volt_l3_v_avg, grid_volt_l3_v_min, grid_volt_l3_v_max, output_volt_v_avg, output_volt_v_min, output_volt_v_max, output_volt_l2_v_avg, output_volt_l2_v_min, output_volt_l2_v_max, output_volt_l3_v_avg, output_volt_l3_v_min, output_volt_l3_v_max, batt_soc_avg, batt_soc_min, batt_soc_max, batt2_soc_avg, batt2_soc_min, batt2_soc_max, batt_temp_c_avg, batt_temp_c_min, batt_temp_c_max, batt2_temp_c_avg, batt2_temp_c_min, batt2_temp_c_max, grid_freq_hz_min, grid_freq_hz_max, load_freq_hz_min, load_freq_hz_max, output_freq_hz_min, output_freq_hz_max, grid_pf_avg, grid_in_w_avg, grid_out_w_avg, batt_pos_w_avg, batt_neg_w_avg, pv_today_kwh, pv_total_kwh, batt_chg_today_kwh, batt_dischg_today_kwh, batt_chg_total_kwh, batt_dischg_total_kwh, grid_import_today_kwh, grid_export_today_kwh, grid_import_total_kwh, grid_export_total_kwh, load_today_kwh, load_total_kwh)
      select plant_id, sn, (ts / 300) * 300,
           count(*),
           count(*) filter (where device_time is not null and not coalesce(carried, false)),
           count(*) filter (where carried),
           (array_agg(status order by ts desc))[1],
           count(distinct status),
           (array_agg(grid_relay_status order by ts desc))[1],
           count(*) filter (where grid_relay_status = '0'),
           count(*) filter (where device_time is not null and grid_volt_v is not null and grid_volt_v <= 100),
           avg(pv_w),
           min(pv_w),
           max(pv_w),
           avg(batt_w),
           min(batt_w),
           max(batt_w),
           avg(batt_power_w),
           min(batt_power_w),
           max(batt_power_w),
           avg(grid_w),
           min(grid_w),
           max(grid_w),
           avg(load_w),
           min(load_w),
           max(load_w),
           avg(output_w),
           min(output_w),
           max(output_w),
           avg(batt2_power_w),
           min(batt2_power_w),
           max(batt2_power_w),
           avg(batt_current_a),
           min(batt_current_a),
           max(batt_current_a),
           avg(batt2_current_a),
           min(batt2_current_a),
           max(batt2_current_a),
           avg(batt_voltage_v),
           min(batt_voltage_v),
           max(batt_voltage_v),
           avg(batt2_voltage_v),
           min(batt2_voltage_v),
           max(batt2_voltage_v),
           avg(grid_volt_v),
           min(grid_volt_v),
           max(grid_volt_v),
           avg(grid_volt_l2_v),
           min(grid_volt_l2_v),
           max(grid_volt_l2_v),
           avg(grid_volt_l3_v),
           min(grid_volt_l3_v),
           max(grid_volt_l3_v),
           avg(output_volt_v),
           min(output_volt_v),
           max(output_volt_v),
           avg(output_volt_l2_v),
           min(output_volt_l2_v),
           max(output_volt_l2_v),
           avg(output_volt_l3_v),
           min(output_volt_l3_v),
           max(output_volt_l3_v),
           avg(nullif(batt_soc, 0)),
           min(nullif(batt_soc, 0)),
           max(nullif(batt_soc, 0)),
           avg(nullif(batt2_soc, 0)),
           min(nullif(batt2_soc, 0)),
           max(nullif(batt2_soc, 0)),
           avg(case when batt_temp_c < -50 then null else batt_temp_c end),
           min(case when batt_temp_c < -50 then null else batt_temp_c end),
           max(case when batt_temp_c < -50 then null else batt_temp_c end),
           avg(case when batt2_temp_c < -50 then null else batt2_temp_c end),
           min(case when batt2_temp_c < -50 then null else batt2_temp_c end),
           max(case when batt2_temp_c < -50 then null else batt2_temp_c end),
           min(grid_freq_hz),
           max(grid_freq_hz),
           min(load_freq_hz),
           max(load_freq_hz),
           min(output_freq_hz),
           max(output_freq_hz),
           avg(grid_pf),
           avg(greatest(grid_w, 0)),
           avg(greatest(-grid_w, 0)),
           avg(greatest(batt_w, 0)),
           avg(greatest(-batt_w, 0)),
           (array_agg(pv_today_kwh order by ts desc) filter (where pv_today_kwh is not null))[1],
           (array_agg(pv_total_kwh order by ts desc) filter (where pv_total_kwh <> 0))[1],
           (array_agg(batt_chg_today_kwh order by ts desc) filter (where batt_chg_today_kwh is not null))[1],
           (array_agg(batt_dischg_today_kwh order by ts desc) filter (where batt_dischg_today_kwh is not null))[1],
           (array_agg(batt_chg_total_kwh order by ts desc) filter (where batt_chg_total_kwh <> 0))[1],
           (array_agg(batt_dischg_total_kwh order by ts desc) filter (where batt_dischg_total_kwh <> 0))[1],
           (array_agg(grid_import_today_kwh order by ts desc) filter (where grid_import_today_kwh is not null))[1],
           (array_agg(grid_export_today_kwh order by ts desc) filter (where grid_export_today_kwh is not null))[1],
           (array_agg(grid_import_total_kwh order by ts desc) filter (where grid_import_total_kwh <> 0))[1],
           (array_agg(grid_export_total_kwh order by ts desc) filter (where grid_export_total_kwh <> 0))[1],
           (array_agg(load_today_kwh order by ts desc) filter (where load_today_kwh is not null))[1],
           (array_agg(load_total_kwh order by ts desc) filter (where load_total_kwh <> 0))[1]
        from public.%I
       where plant_id is not null
       group by plant_id, sn, (ts / 300) * 300
      on conflict do nothing$q$, p_child);
  elsif p_parent = 'strings' then
    execute format($q$
      insert into public.strings_5m (plant_id, sn, no, ts, n, volt_v_avg, volt_v_min, volt_v_max, current_a_avg, current_a_min, current_a_max, power_w_avg, power_w_min, power_w_max, today_kwh)
      select plant_id, sn, no, (ts / 300) * 300,
           count(*),
           avg(volt_v),
           min(volt_v),
           max(volt_v),
           avg(current_a),
           min(current_a),
           max(current_a),
           avg(power_w),
           min(power_w),
           max(power_w),
           (array_agg(today_kwh order by ts desc) filter (where today_kwh <> 0))[1]
        from public.%I
       where plant_id is not null
       group by plant_id, sn, no, (ts / 300) * 300
      on conflict do nothing$q$, p_child);
  else
    raise exception 'rollup_partition: unknown parent %', p_parent;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.api_trends_compare(p_plant bigint default null)
returns jsonb
language sql
stable
security definer
set search_path to public, pg_temp
as $fn$
  with pl as (select public.my_plant(p_plant) as id),
  tz as (select public.plant_tz((select id from pl)) as tz),
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
  -- each known inverter with a row in the last 2 days (SOLAR-555; was: those in today's
  -- latest poll, which drops one the poller left out): its last good reading on the matching day at or
  -- before the moment, from readings, else the 5-minute history (counters as at the
  -- bucket's end). One index probe per inverter per pair.
  inv as (
    select i.sn from private.inverters i
     where i.plant_id = (select id from pl)
       and exists (select 1 from public.readings r
                    where r.sn = i.sn and r.plant_id = i.plant_id
                      and r.ts > extract(epoch from now())::bigint - 2 * 86400 and r.ts <= (select ts from latest))
  ),
  per as (
    select tc.k, i.sn,
           coalesce(x.pv, y.pv) as pv, coalesce(x.load, y.load) as load, coalesce(x.imp, y.imp) as imp,
           (x.ts is not null or y.ts is not null) as found
      from tc cross join inv i
      left join lateral (
        -- an upload dated before the matching day holds that day's eve: 0 so far (SOLAR-648)
        select r.ts,
               case when r.device_time ~ '^\d{4}-\d{2}-\d{2} ' and left(r.device_time, 10) < tc.prev::text then 0 else r.pv_today_kwh end as pv,
               case when r.device_time ~ '^\d{4}-\d{2}-\d{2} ' and left(r.device_time, 10) < tc.prev::text then 0 else r.load_today_kwh end as load,
               case when r.device_time ~ '^\d{4}-\d{2}-\d{2} ' and left(r.device_time, 10) < tc.prev::text then 0 else r.grid_import_today_kwh end as imp
          from public.readings r
         where r.sn = i.sn and r.plant_id = (select id from pl)
           and r.ts >= tc.lo and r.ts <= tc.cut and r.device_time is not null
         order by r.ts desc limit 1) x on true
      left join lateral (
        select f.ts, f.pv_today_kwh as pv, f.load_today_kwh as load, f.grid_import_today_kwh as imp
          from public.readings_5m f
         where x.ts is null
           and f.plant_id = (select id from pl) and f.sn = i.sn
           and f.ts >= tc.lo and f.ts <= tc.cut - 300 and f.pv_today_kwh is not null
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

-- 3a. minute rows uploaded before their own day: today so far is 0
update public.readings
   set pv_today_kwh = case when pv_today_kwh is null then null else 0 end,
       load_today_kwh = case when load_today_kwh is null then null else 0 end,
       batt_chg_today_kwh = case when batt_chg_today_kwh is null then null else 0 end,
       batt_dischg_today_kwh = case when batt_dischg_today_kwh is null then null else 0 end,
       grid_import_today_kwh = case when grid_import_today_kwh is null then null else 0 end,
       grid_export_today_kwh = case when grid_export_today_kwh is null then null else 0 end
 where device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
   and left(device_time, 10) < to_char(to_timestamp(ts) at time zone public.plant_tz(plant_id), 'YYYY-MM-DD')
   and (coalesce(pv_today_kwh, 0) <> 0 or coalesce(load_today_kwh, 0) <> 0 or coalesce(batt_chg_today_kwh, 0) <> 0 or coalesce(batt_dischg_today_kwh, 0) <> 0 or coalesce(grid_import_today_kwh, 0) <> 0 or coalesce(grid_export_today_kwh, 0) <> 0);

-- 3b. 5-minute buckets in a day's first 15 minutes: a today counter cannot fall later that
-- day, so one above a later bucket's (or above 0 when every later bucket is 0) is yesterday's
update public.readings_5m f
   set pv_today_kwh = case when f.pv_today_kwh > coalesce((select min(l.pv_today_kwh) from public.readings_5m l
                                         where l.plant_id = f.plant_id and l.sn = f.sn and l.ts > f.ts
                                           and l.ts < public.day_start_epoch_tz(d.day + 1, d.tz)), 0)
                  then 0 else f.pv_today_kwh end,
       load_today_kwh = case when f.load_today_kwh > coalesce((select min(l.load_today_kwh) from public.readings_5m l
                                         where l.plant_id = f.plant_id and l.sn = f.sn and l.ts > f.ts
                                           and l.ts < public.day_start_epoch_tz(d.day + 1, d.tz)), 0)
                  then 0 else f.load_today_kwh end,
       batt_chg_today_kwh = case when f.batt_chg_today_kwh > coalesce((select min(l.batt_chg_today_kwh) from public.readings_5m l
                                         where l.plant_id = f.plant_id and l.sn = f.sn and l.ts > f.ts
                                           and l.ts < public.day_start_epoch_tz(d.day + 1, d.tz)), 0)
                  then 0 else f.batt_chg_today_kwh end,
       batt_dischg_today_kwh = case when f.batt_dischg_today_kwh > coalesce((select min(l.batt_dischg_today_kwh) from public.readings_5m l
                                         where l.plant_id = f.plant_id and l.sn = f.sn and l.ts > f.ts
                                           and l.ts < public.day_start_epoch_tz(d.day + 1, d.tz)), 0)
                  then 0 else f.batt_dischg_today_kwh end,
       grid_import_today_kwh = case when f.grid_import_today_kwh > coalesce((select min(l.grid_import_today_kwh) from public.readings_5m l
                                         where l.plant_id = f.plant_id and l.sn = f.sn and l.ts > f.ts
                                           and l.ts < public.day_start_epoch_tz(d.day + 1, d.tz)), 0)
                  then 0 else f.grid_import_today_kwh end,
       grid_export_today_kwh = case when f.grid_export_today_kwh > coalesce((select min(l.grid_export_today_kwh) from public.readings_5m l
                                         where l.plant_id = f.plant_id and l.sn = f.sn and l.ts > f.ts
                                           and l.ts < public.day_start_epoch_tz(d.day + 1, d.tz)), 0)
                  then 0 else f.grid_export_today_kwh end
  from (select x.plant_id, x.sn, x.ts, public.plant_tz(x.plant_id) as tz,
               (to_timestamp(x.ts) at time zone public.plant_tz(x.plant_id))::date as day
          from public.readings_5m x
         where (to_timestamp(x.ts) at time zone public.plant_tz(x.plant_id))::time < '00:15') d
 where f.plant_id = d.plant_id and f.sn = d.sn and f.ts = d.ts;
