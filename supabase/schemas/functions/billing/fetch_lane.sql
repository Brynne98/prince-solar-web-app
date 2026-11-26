CREATE OR REPLACE FUNCTION billing.fetch_lane(p_account uuid, p_plant bigint)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'private', 'pg_temp'
AS $function$
  select coalesce(
    (select l.id from plants.logins l
       join plants.login_plants lp on lp.login = l.id and lp.plant = p_plant and lp.gone_at is null
       join plants.logins sa on sa.id = l.id and sa.status = 'ok'
      where l.account = p_account and l.status = 'ok'
      order by l.linked_at, l.id limit 1),
    (select sa.id from plants.claims c
       join plants.logins sa on sa.kind = 'share' and sa.status = 'ok' and sa.brand = plants.brand_of(c.plant)
      where c.account = p_account and c.plant = p_plant limit 1))
$function$;
