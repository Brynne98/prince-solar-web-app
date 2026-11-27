CREATE OR REPLACE FUNCTION history.spent(p_shard integer, p_reserved integer, p_calls integer, p_at timestamp with time zone)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into history.calls as hc (minute, shard, calls)
  select date_trunc('minute', p_at), coalesce(p_shard, 0), greatest(p_calls - coalesce(p_reserved, 0), 0)
   where p_calls is not null and p_calls > coalesce(p_reserved, 0)
  on conflict (minute, shard) do update set calls = hc.calls + excluded.calls
$function$;
