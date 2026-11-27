CREATE OR REPLACE FUNCTION plants.throttled(p_login uuid, p_since timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select l.throttled_at > p_since from plants.logins l where l.id = p_login), false)
$function$;
