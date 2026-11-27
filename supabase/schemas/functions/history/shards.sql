CREATE OR REPLACE FUNCTION history.shards(p_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(shard integer, shards integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with n as (select greatest(1, ceil(count(distinct r.lane) / 25.0))::integer as k from billing.reading_routes(p_at) r)
  select g, n.k from n, generate_series(0, n.k - 1) g
$function$;
