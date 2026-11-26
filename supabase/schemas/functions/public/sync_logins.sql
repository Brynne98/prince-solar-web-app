CREATE OR REPLACE FUNCTION public.sync_logins()
 RETURNS TABLE(id uuid, user_id uuid, username text, brand text, access_token text, access_expires_at bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select l.id, l.user_id, l.username, l.brand, l.access_token, l.access_expires_at
    from plants.logins l where l.status = 'ok' order by l.id
$function$;
