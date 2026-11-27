CREATE OR REPLACE FUNCTION public.login_throttled(p_login uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update plants.logins set throttled_at = now() where id = p_login
$function$;
