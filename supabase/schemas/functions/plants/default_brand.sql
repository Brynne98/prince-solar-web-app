CREATE OR REPLACE FUNCTION plants.default_brand()
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select b.code from plants.brands b where b.is_default
$function$;
