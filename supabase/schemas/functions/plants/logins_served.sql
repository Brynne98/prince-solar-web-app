CREATE OR REPLACE FUNCTION plants.logins_served(p_plants bigint[], p_except uuid[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update plants.logins s set last_ok_at = now()
   where s.id in (select o.id from plants.logins o
                   where o.status = 'ok' and o.id <> all (coalesce(p_except, '{}'))
                     and exists (select 1 from plants.user_plants pu where pu.account_id = o.id and pu.plant_id = any (coalesce(p_plants, '{}')))
                   order by o.id for no key update skip locked)
$function$;
