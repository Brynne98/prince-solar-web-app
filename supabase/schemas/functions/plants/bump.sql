CREATE OR REPLACE FUNCTION plants.bump(p_plants bigint[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- locks in id order first, as billing.lock_plants does: never a deadlock with a save (R19)
  select null from (select p.id from plants.plants p where p.id = any (coalesce(p_plants, '{}')) order by p.id for update) x;
  update plants.plants set version = version + 1 where id = any (coalesce(p_plants, '{}'))
$function$;
