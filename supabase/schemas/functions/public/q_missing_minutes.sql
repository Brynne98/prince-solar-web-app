CREATE OR REPLACE FUNCTION public.q_missing_minutes(p_plant bigint, p_day date)
 RETURNS TABLE(ts bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with b as (
    select (select min(a.ts) from public.agg_minute a where a.plant_id = p_plant) as first_ts,
           (select public.day_start_epoch_tz(c.backfill_next, public.plant_tz(p_plant))
              from public.plant_config c where c.plant_id = p_plant and c.backfill_next is not null) as bf_ts,
           public.day_start_epoch_tz(p_day, public.plant_tz(p_plant))            as day_start,
           extract(epoch from now())::bigint                                    as now_ts
  ),
  bounds as (
    select ceil(greatest(day_start, least(first_ts, bf_ts)) / 60.0)::bigint * 60 as lo,
           least(day_start + 86400, now_ts - 600)                                as hi
      from b where first_ts is not null or bf_ts is not null
  )
  select g as ts from bounds, generate_series(bounds.lo, bounds.hi - 60, 60) g
   where bounds.hi > bounds.lo
     and not exists (select 1 from public.agg_minute a where a.plant_id = p_plant and a.ts = g
                                                  and a.source <> 'poller_partial')
   order by g
$function$;
