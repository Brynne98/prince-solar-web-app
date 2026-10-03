-- ============================================================================
-- 0064 — api_balance finds the newest battery reading without reading them all. (SOLAR-35)
--
-- On 2026-10-03 api_balance failed about 2 calls in 3 (341 of 521 in 24 h, every
-- device) with "canceling statement due to statement timeout" at the 8 s limit
-- for authenticated. latest_ts asked for max(ts) with the plant id coming from a
-- CTE, so the planner could not prune or stop early: it seq-scanned every monthly
-- partition, about 260,000 rows, in 5.4 s, growing with history. "order by ts desc
-- limit 1" walks the (plant_id, ts) index backwards and stops at the first row:
-- 0.2 ms. Same result, including NULL when there is no reading (the scalar
-- subquery keeps that), so the output shape is unchanged for the phone app.
-- Only latest_ts changes; the rest is the live definition as of 0063.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.api_balance(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  now_s as (select extract(epoch from now())::bigint as t),
  -- newest first, take one: max(ts) read every month of readings, because the plant id
  -- comes from pl and the planner can't use the index to stop early (SOLAR-35)
  latest_ts as (select (select ts from public.readings where plant_id = (select id from pl) and batt_soc is not null order by ts desc limit 1) as ts),
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
$function$;
