CREATE OR REPLACE FUNCTION billing.is_live()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select exists (select 1 from billing.switch_over)
$function$;
