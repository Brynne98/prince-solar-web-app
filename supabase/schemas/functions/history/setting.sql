CREATE OR REPLACE FUNCTION history.setting(p_key text, p_default integer)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select c.value::integer from public.app_config c where c.key = p_key), p_default)
$function$;
