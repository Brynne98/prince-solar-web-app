CREATE OR REPLACE FUNCTION billing.live_sub(p_account uuid)
 RETURNS billing.subscriptions
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select * from billing.subscriptions where account = p_account and status in ('active', 'past_due')
$function$;
