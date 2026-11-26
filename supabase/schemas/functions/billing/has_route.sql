CREATE OR REPLACE FUNCTION billing.has_route(p_account uuid, p_plant bigint, p_need_ok boolean)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select exists (select 1 from billing.logins l join billing.login_plants lp on lp.login = l.id
                  where l.account = p_account and lp.plant = p_plant and lp.gone_at is null
                    and (not p_need_ok or l.status = 'ok'))
      or exists (select 1 from billing.plant_claims c where c.account = p_account and c.plant = p_plant)
$function$;
