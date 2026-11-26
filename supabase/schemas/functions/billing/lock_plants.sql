CREATE OR REPLACE FUNCTION billing.lock_plants(p_plants bigint[])
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select null from (select id from plants.plants where id = any (p_plants) order by id for update) x
$function$;
