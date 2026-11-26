CREATE OR REPLACE FUNCTION plants.calls_on(p_day date)
 RETURNS TABLE(calls bigint, failed bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(sum(k.calls), 0)::bigint,
         coalesce(sum(k.calls) filter (where k.result in ('429', '403_throttle', '5xx', 'network', 'timeout')), 0)::bigint
    from plants.brand_calls k where k.day = p_day and k.brand <> ''
$function$;
