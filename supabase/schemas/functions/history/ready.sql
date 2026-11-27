CREATE OR REPLACE FUNCTION history.ready(p_plant bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from history.imports i where i.plant = p_plant and i.status = 'done')
      or (not exists (select 1 from history.imports i where i.plant = p_plant and i.status = 'open')
          and exists (select 1 from public.agg_minute a where a.plant_id = p_plant))
$function$;
