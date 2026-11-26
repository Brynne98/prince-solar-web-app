CREATE OR REPLACE FUNCTION billing.readings_resume(p_account uuid, p_at timestamp with time zone)
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select billing.readings_start(p_account, array(select plant from billing.seats where account = p_account and closed_at is null), p_at)
$function$;
