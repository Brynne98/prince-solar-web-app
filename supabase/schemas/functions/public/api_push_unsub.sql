CREATE OR REPLACE FUNCTION public.api_push_unsub(p_endpoint text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  delete from public.push_subs where endpoint = p_endpoint and user_id = auth.uid();
$function$;
