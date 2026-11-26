CREATE OR REPLACE FUNCTION plants.user_plant_ids(p_user uuid)
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select distinct u.plant_id from plants.user_plants u where u.user_id = p_user and u.share_gone_at is null
$function$;
