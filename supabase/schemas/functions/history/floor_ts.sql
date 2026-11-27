CREATE OR REPLACE FUNCTION history.floor_ts(p_plant bigint)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select least((select min(a.ts) from public.agg_minute a where a.plant_id = p_plant),
               (select public.day_start_epoch_tz(min(i.floor_day), plants.tz(p_plant))
                  from history.imports i where i.plant = p_plant and i.status <> 'stopped'))
$function$;
