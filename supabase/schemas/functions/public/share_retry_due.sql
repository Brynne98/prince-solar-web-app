CREATE OR REPLACE FUNCTION public.share_retry_due()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select a.id from private.sunsynk_accounts a
   where a.kind = 'share' and a.status = 'needs_relink'
     and coalesce((select max(e.at) from private.sunsynk_login_events e
                    where e.account_id = a.id and e.event = 'died'), '-infinity') < now() - interval '55 minutes'
$function$;
