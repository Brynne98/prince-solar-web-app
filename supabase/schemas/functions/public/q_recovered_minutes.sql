CREATE OR REPLACE FUNCTION public.q_recovered_minutes(p_plant bigint, p_day date)
 RETURNS bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with b as (select public.day_start_epoch_tz(p_day, public.plant_tz(p_plant)) as lo)
  select (select count(*) from public.agg_minute a, b
           where a.plant_id = p_plant and coalesce(a.source, 'poller') <> 'poller'
             and a.ts >= b.lo and a.ts < b.lo + 86400)
       + (select coalesce(sum(f.n - f.n_poller), 0) from public.agg_5m f, b
           where f.plant_id = p_plant and f.ts >= b.lo and f.ts < b.lo + 86400)
$function$;
