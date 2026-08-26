-- ============================================================================
-- Hour-of-day load split (solar / battery / grid → house) on q_by_hour.
--
-- q_by_hour already averaged pv/load/grid/soc on complete days. The Live battery
-- node uses that SOC as "usually N% at this hour". Trends → Battery wants the
-- same grain for the mix: what typically covers the house at 23:00, not just in
-- the five coarse day-segments.
--
-- Same decomposition as q_segment_power, so the two views agree:
--   solar→load = min(pv, load)
--   batt→load  = discharging ? min(−batt, remainder) : 0
--   grid→load  = remainder − batt→load
-- Grid that only charged the battery stays out of the house mix. Existing
-- columns (including raw grid_w) keep their meaning; the split is additive.
--
-- Table-function OUT columns can't be added with CREATE OR REPLACE, so both
-- q_by_hour and its jsonb wrapper are dropped and recreated.
-- ============================================================================

drop function if exists public.api_trends_by_hour(integer);
drop function if exists public.q_by_hour(integer);

create function public.q_by_hour(p_days integer default 14)
returns table (
  hour integer, pv_w numeric, load_w numeric, baseline_load_w numeric,
  grid_w numeric, soc numeric, samples bigint, surplus_w numeric, spare_w numeric,
  solar_w numeric, batt_load_w numeric, grid_load_w numeric)
language sql stable as $$
  with since as (select (extract(epoch from now())::bigint - p_days * 86400) as t),
  day_stats as (
    select public.local_day(ts) as d, count(distinct public.local_hour(ts)) as hours
      from public.agg_minute, since where ts >= since.t group by 1
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
     where ts >= since.t
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
           -- HEAVY_LOAD_W = 1500: deferrable loads (geyser, kettle, oven, aircon, EV)
           -- are excluded so "spare solar" reflects genuine headroom.
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

create function public.api_trends_by_hour(p_days integer default 14)
returns jsonb language sql stable as $$
  select jsonb_build_object('days', p_days,
    'hours', coalesce((select jsonb_agg(to_jsonb(h) order by h.hour) from public.q_by_hour(p_days) h), '[]'::jsonb))
$$;

revoke all on function public.q_by_hour(integer) from public, anon;
revoke all on function public.api_trends_by_hour(integer) from public, anon;
grant execute on function public.q_by_hour(integer) to authenticated, service_role;
grant execute on function public.api_trends_by_hour(integer) to authenticated, service_role;

notify pgrst, 'reload schema';
