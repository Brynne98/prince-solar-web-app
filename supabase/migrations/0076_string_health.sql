-- ============================================================================
-- 0076 — is each panel string doing its usual share? (SOLAR-51)
--
-- The Panels card showed volts, amps and a "check" badge that lit on empty
-- inputs floating near 1.5 V. It now says whether the panels are working
-- normally and names a string only when it really underperforms.
--
-- SunSynk's per-string today_kwh is always 0, so energy is power added up from
-- the minute rows. Each string's share of the solar is steady (0.7-3.8 points of
-- spread over 15 days on both plants, measured 6 Oct 2026), so a string well
-- below its usual share on a day with real sun is a fault worth naming.
--
-- api_string_health(p_plant) returns, per inverter and per used string:
--   * today: kWh since local midnight, and its share of the inverter's and of
--     the plant's used-string solar;
--   * usual: the average of those shares over the last 14 days, each day cut
--     at the same time of day as now (east and west strings differ through
--     the morning), counting only days whose window made more than 1 kWh;
--   * historyDays: how many such days there were;
--   * battFull: the inverter's battery reached 98% today, when it may turn its
--     panels down and single-string comparisons stop being fair;
--   * lastTs: the newest string reading today.
-- A string that never reached 50 W in 14 days is an empty input and is left out.
-- The verdict itself (thresholds, wording) lives in the page.
-- ============================================================================

create or replace function public.api_string_health(p_plant bigint default null)
returns jsonb
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  z as (select public.plant_tz((select id from pl)) as tz),
  t as (
    select public.day_start_epoch_tz(public.today_tz((select tz from z)), (select tz from z)) as t0,
           extract(epoch from now())::bigint as nw
  ),
  w as (select greatest((select nw from t) - (select t0 from t), 60) as len),
  days as (
    select g as k, public.day_start_epoch_tz(public.today_tz((select tz from z)) - g, (select tz from z)) as d0
      from generate_series(0, 14) g
  ),
  used as (
    select st.sn, st.no
      from public.strings st
     where st.plant_id = (select id from pl)
       and st.ts >= (select d0 from days where k = 14)
       and st.power_w >= 50
     group by st.sn, st.no
  ),
  s as (
    select d.k, st.sn, st.no, sum(greatest(st.power_w, 0)) / 60000.0 as kwh
      from days d
      join public.strings st
        on st.plant_id = (select id from pl)
       and st.ts >= d.d0 and st.ts < d.d0 + (select len from w)
      join used u on u.sn = st.sn and u.no = st.no
     group by d.k, st.sn, st.no
  ),
  tot as (
    select k, sn, kwh,
           sum(kwh) over (partition by k, sn) as inv_kwh,
           sum(kwh) over (partition by k) as plant_kwh,
           no
      from s
  ),
  shares as (
    select k, sn, no, kwh, plant_kwh,
           case when inv_kwh > 0 then kwh / inv_kwh end as inv_share,
           case when plant_kwh > 0 then kwh / plant_kwh end as plant_share
      from tot
  ),
  usual as (
    select sn, no, avg(inv_share) as inv_share, avg(plant_share) as plant_share
      from shares
     where k between 1 and 14 and plant_kwh > 1
     group by sn, no
  ),
  hist as (
    select count(distinct k) as n from shares where k between 1 and 14 and plant_kwh > 1
  ),
  batt as (
    select r.sn, max(r.batt_soc) >= 98 as full
      from public.readings r
     where r.plant_id = (select id from pl) and r.ts >= (select t0 from t)
     group by r.sn
  ),
  last as (
    select st.sn, max(st.ts) as ts
      from public.strings st
     where st.plant_id = (select id from pl) and st.ts >= (select t0 from t)
     group by st.sn
  ),
  inv as (
    select u.sn,
           jsonb_agg(jsonb_build_object(
             'no', u.no,
             'todayKwh', round(coalesce(td.kwh, 0)::numeric, 2),
             'todayInvShare', round(td.inv_share::numeric, 4),
             'todayPlantShare', round(td.plant_share::numeric, 4),
             'usualInvShare', round(us.inv_share::numeric, 4),
             'usualPlantShare', round(us.plant_share::numeric, 4)) order by u.no) as strings
      from used u
      left join shares td on td.k = 0 and td.sn = u.sn and td.no = u.no
      left join usual us on us.sn = u.sn and us.no = u.no
     group by u.sn
  )
  select jsonb_build_object(
    'historyDays', (select n from hist),
    'todayKwh', round(coalesce((select max(plant_kwh) from shares where k = 0), 0)::numeric, 2),
    'inverters', coalesce((select jsonb_agg(jsonb_build_object(
        'sn', i.sn,
        'battFull', coalesce(b.full, false),
        'lastTs', l.ts,
        'strings', i.strings) order by i.sn)
      from inv i left join batt b on b.sn = i.sn left join last l on l.sn = i.sn), '[]'::jsonb))
$$;
revoke all on function public.api_string_health(bigint) from public, anon;
grant execute on function public.api_string_health(bigint) to authenticated, service_role;
