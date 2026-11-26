CREATE OR REPLACE FUNCTION public.api_notifications_read(p_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  update public.email_queue
     set read_at = now()
   where user_id = auth.uid() and read_at is null
     and private.is_alert(kind)
     and (p_ids is null or id = any (p_ids));
  if p_ids is null then perform public.api_notices_read(null); end if;
end $function$;
