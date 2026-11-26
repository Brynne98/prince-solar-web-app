CREATE OR REPLACE FUNCTION public.plant_history_loading(p_plant bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from public.plant_config c where c.plant_id = p_plant and c.backfill_next is not null)
$function$;
