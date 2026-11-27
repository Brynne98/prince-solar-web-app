CREATE OR REPLACE FUNCTION history.missing(p_id bigint, p_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(ts bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with d as (select x.plant, x.day, x.import, plants.tz(x.plant) tz from history.days x where x.id = p_id),
  b as (
    select d.plant,
           case when d.import is null then greatest(public.day_start_epoch_tz(d.day, d.tz), (ceil(history.floor_ts(d.plant) / 60.0) * 60)::bigint)
                else public.day_start_epoch_tz(d.day, d.tz) end as lo,
           least(public.day_start_epoch_tz(d.day + 1, d.tz), extract(epoch from p_at)::bigint - 600) as hi
      from d)
  select g from b, generate_series(b.lo, b.hi - 60, 60) g
   where b.hi > b.lo and b.lo is not null
     and not exists (select 1 from public.agg_minute a where a.plant_id = b.plant and a.ts = g and a.source <> 'poller_partial')
     -- past 31 days a minute lives in its five-minute row (agg_minute_rollup): held, not missing
     and not exists (select 1 from public.agg_5m f where f.plant_id = b.plant and f.ts = g - g % 300)
   order by g
$function$;
