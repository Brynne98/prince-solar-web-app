CREATE OR REPLACE FUNCTION public.account_by_username(p_username text)
 RETURNS TABLE(id uuid, user_id uuid, status text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  select id, user_id, status from plants.logins where username = p_username
$function$;
