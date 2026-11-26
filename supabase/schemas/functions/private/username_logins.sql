CREATE OR REPLACE FUNCTION private.username_logins(p_user uuid, p_username text)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
  select coalesce(array_agg(sa.id order by sa.id), '{}') from private.sunsynk_accounts sa
   where lower(sa.sunsynk_username) = lower(p_username)
     and ((sa.user_id = p_user and sa.kind = 'login') or sa.status <> 'disabled')
$function$;
