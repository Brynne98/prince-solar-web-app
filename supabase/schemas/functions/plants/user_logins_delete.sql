CREATE OR REPLACE FUNCTION plants.user_logins_delete(p_user uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  delete from plants.logins where user_id = p_user
$function$;
