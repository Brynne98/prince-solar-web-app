CREATE OR REPLACE FUNCTION plants.brand_of(p_plant bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p.brand from plants.plants p where p.id = p_plant
$function$;
