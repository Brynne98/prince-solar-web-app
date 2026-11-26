CREATE OR REPLACE FUNCTION private.plant_live(p_user uuid, p_plant bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select coalesce(billing.reads_plant((select id from billing.accounts where user_id = p_user), p_plant, now()), false)
$function$;
