CREATE OR REPLACE FUNCTION billing.fetch_lane(p_account uuid, p_plant bigint)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'private', 'pg_temp'
AS $function$
  select coalesce(
    (select l.id from billing.logins l
       join billing.login_plants lp on lp.login = l.id and lp.plant = p_plant and lp.gone_at is null
       join private.sunsynk_accounts sa on sa.id = l.id and sa.status = 'active'
      where l.account = p_account and l.status = 'ok'
      order by l.created_at, l.id limit 1),
    (select sa.id from billing.plant_claims c
       join private.sunsynk_accounts sa on sa.kind = 'share' and sa.status = 'active'
      where c.account = p_account and c.plant = p_plant limit 1))
$function$;
