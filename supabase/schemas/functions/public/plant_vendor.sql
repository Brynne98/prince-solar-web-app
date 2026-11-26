CREATE OR REPLACE FUNCTION public.plant_vendor(p_plant bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p.vendor_id from plants.plants p where p.id = p_plant
$function$;
