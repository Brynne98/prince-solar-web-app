CREATE OR REPLACE FUNCTION plants.bump(p_plants bigint[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update plants.plants set version = version + 1 where id = any (coalesce(p_plants, '{}'))
$function$;
