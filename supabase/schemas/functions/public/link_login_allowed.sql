CREATE OR REPLACE FUNCTION public.link_login_allowed(p_user uuid, p_username text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select plants.link_allowed(p_user, plants.default_brand(), p_username)
$function$;
