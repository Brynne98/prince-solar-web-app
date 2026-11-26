CREATE OR REPLACE FUNCTION billing.bump(p_account uuid)
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  update billing.accounts set version = version + 1 where id = p_account
$function$;
