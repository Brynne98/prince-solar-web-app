CREATE OR REPLACE FUNCTION public.q_missing_minutes_day(p_plant bigint, p_day date)
 RETURNS TABLE(ts bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with b as (
    select public.day_start_epoch_tz(p_day, public.plant_tz(p_plant)) as lo,
           least(public.day_start_epoch_tz(p_day + 1, public.plant_tz(p_plant)),
                 extract(epoch from now())::bigint - 600) as hi)
  select g from b, generate_series(b.lo, b.hi - 60, 60) g
   where b.hi > b.lo
     and not exists (select 1 from public.agg_minute a where a.plant_id = p_plant and a.ts = g
                                                  and a.source <> 'poller_partial')
   order by g
$function$;
