CREATE OR REPLACE FUNCTION public.q_stats(p_plant bigint)
 RETURNS TABLE(agg_rows bigint, days bigint, first_ts bigint, last_ts bigint, per_inverter_rows bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pz as (select public.plant_tz(p_plant) as tz)
  select
    (select count(*) from public.agg_minute where plant_id = p_plant)
      + (select coalesce(sum(n), 0) from public.agg_5m where plant_id = p_plant)::bigint,
    (select count(distinct d) from (
        select public.local_day_tz(ts, (select tz from pz)) d from public.agg_minute where plant_id = p_plant
        union
        select public.local_day_tz(ts, (select tz from pz)) from public.agg_5m where plant_id = p_plant) x),
    least((select min(ts) from public.agg_minute where plant_id = p_plant),
          (select min(ts) from public.agg_5m where plant_id = p_plant)),
    (select max(ts) from public.agg_minute where plant_id = p_plant),
    (select count(*) from public.readings where plant_id = p_plant)
$function$;
