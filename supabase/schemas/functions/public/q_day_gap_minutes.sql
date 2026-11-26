CREATE OR REPLACE FUNCTION public.q_day_gap_minutes(p_plant bigint, p_day date)
 RETURNS bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pz as (select public.plant_tz(p_plant) as tz),
  b as (
    select least((select min(ts) from public.agg_minute where plant_id = p_plant),
                 (select min(ts) from public.agg_5m where plant_id = p_plant)) as first_ts,
           public.day_start_epoch_tz(p_day, (select tz from pz))          as day_start,
           extract(epoch from now())::bigint                              as now_ts
  ),
  w as (select greatest(day_start, first_ts) as lo, least(day_start + 86400, now_ts) as hi from b where first_ts is not null)
  select case when w.hi <= w.lo then null
              else greatest(0, round((w.hi - w.lo) / 60.0)::bigint
                   - (select count(*) from public.agg_minute where plant_id = p_plant and ts >= w.lo and ts < w.hi)
                   - (select coalesce(sum(n), 0) from public.agg_5m where plant_id = p_plant and ts >= w.lo and ts < w.hi))
         end
    from w
$function$;
