CREATE OR REPLACE FUNCTION plants.market_tz()
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select m.default_time_zone from billing.markets m order by m.code limit 1
$function$;
