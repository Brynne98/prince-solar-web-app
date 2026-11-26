CREATE OR REPLACE FUNCTION public.independence_pct(p_home double precision, p_import double precision)
 RETURNS double precision
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case when coalesce(p_home, 0) > 0
              then greatest(0, least(100, ((p_home - coalesce(p_import, 0)) / p_home) * 100)) else 0 end
$function$;
