CREATE OR REPLACE FUNCTION public.q_by_hour(p_plant bigint, p_days integer DEFAULT 14)
 RETURNS TABLE(hour integer, pv_w numeric, load_w numeric, baseline_load_w numeric, grid_w numeric, soc numeric, samples bigint, surplus_w numeric, spare_w numeric, solar_w numeric, batt_load_w numeric, grid_load_w numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pz as (select public.plant_tz(p_plant) as tz),
  since as (select (extract(epoch from now())::bigint - p_days * 86400) as t),
  day_stats as (
    select public.local_day_tz(ts, (select tz from pz)) as d, count(distinct public.local_hour_tz(ts, (select tz from pz))) as hours
      from public.agg_minute, since where plant_id = p_plant and ts >= since.t group by 1
  ),
  d as (
    select public.local_hour_tz(ts, (select tz from pz)) as hour,
           coalesce(pv_w, 0) as pv, coalesce(load_w, 0) as load, coalesce(batt_w, 0) as batt, coalesce(grid_w, 0) as grid, soc,
           least(coalesce(pv_w, 0), coalesce(load_w, 0)) as s2l
      from public.agg_minute, since
     where plant_id = p_plant and ts >= since.t
       and public.local_day_tz(ts, (select tz from pz)) in (select d from day_stats where hours >= 24)
  ),
  e as (select hour, pv, load, batt, grid, soc, s2l, (load - s2l) as rem,
               case when batt < 0 then least(-batt, load - s2l) else 0 end as b2l from d),
  base as (
    select hour, round(avg(pv)::numeric) as pv_w, round(avg(load)::numeric) as load_w,
           round(avg(case when load < 1500 then load end)::numeric) as baseline_load_w,
           round(avg(grid)::numeric) as grid_w, round(avg(soc)::numeric) as soc, count(*) as samples,
           round(avg(s2l)::numeric) as solar_w, round(avg(b2l)::numeric) as batt_load_w, round(avg(rem - b2l)::numeric) as grid_load_w
      from e group by 1
  )
  select hour, pv_w, load_w, coalesce(baseline_load_w, load_w) as baseline_load_w, grid_w, soc, samples,
         round(coalesce(pv_w,0) - coalesce(load_w,0)) as surplus_w,
         round(coalesce(pv_w,0) - coalesce(coalesce(baseline_load_w, load_w),0)) as spare_w,
         solar_w, batt_load_w, grid_load_w
    from base order by hour
$function$;
