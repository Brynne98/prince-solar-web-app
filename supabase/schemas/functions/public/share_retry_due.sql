CREATE OR REPLACE FUNCTION public.share_retry_due()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select a.id from plants.logins a
   where a.kind = 'share' and a.status = 'needs_reconnect'
     and coalesce((select max(e.at) from plants.login_events e
                    where e.account_id = a.id and e.event = 'died'), '-infinity') < now() - interval '55 minutes'
$function$;
