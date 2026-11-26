CREATE OR REPLACE FUNCTION public.share_account_get()
 RETURNS TABLE(id uuid, user_id uuid, username text, access_token text, access_expires_at bigint, status text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  select a.id, a.user_id, a.username, a.access_token, a.access_expires_at, a.status
    from plants.logins a where a.kind = 'share'
$function$;
