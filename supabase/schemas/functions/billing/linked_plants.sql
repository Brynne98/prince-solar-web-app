CREATE OR REPLACE FUNCTION billing.linked_plants(p_account uuid)
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select lp.plant from billing.logins l join billing.login_plants lp on lp.login = l.id
   where l.account = p_account and lp.gone_at is null
  union
  select c.plant from billing.plant_claims c where c.account = p_account
$function$;
