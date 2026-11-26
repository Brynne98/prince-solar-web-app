CREATE OR REPLACE FUNCTION plants.run_last_at(p_shard integer, p_since date)
 RETURNS timestamp with time zone
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select max(k.last_at) from plants.brand_calls k
   where k.brand = '' and k.kind = 'poll_run' and k.result = 's' || p_shard and k.day >= p_since
$function$;
