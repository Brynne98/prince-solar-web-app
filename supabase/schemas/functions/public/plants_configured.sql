CREATE OR REPLACE FUNCTION public.plants_configured(p_plants bigint[])
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select c.plant_id from public.plant_config c where c.plant_id = any (coalesce(p_plants, '{}'))
$function$;
