CREATE OR REPLACE FUNCTION plants.tz(p_plant bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select p.time_zone from plants.plants p where p.id = p_plant),
                  (select m.default_time_zone from billing.markets m order by m.code limit 1))
$function$;
