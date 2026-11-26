CREATE OR REPLACE FUNCTION billing.active_method(p_account uuid)
 RETURNS billing.payment_methods
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select * from billing.payment_methods where account = p_account and active
$function$;
