CREATE OR REPLACE FUNCTION public.cfg(p_key text)
 RETURNS double precision
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$
  select value from public.app_config where key = p_key
$function$;
