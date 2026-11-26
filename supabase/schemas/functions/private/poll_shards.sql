CREATE OR REPLACE FUNCTION private.poll_shards(p_per_shard integer DEFAULT 10)
 RETURNS TABLE(shard integer, shards integer, delay_ms integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_temp'
AS $function$
  with n as (
    select greatest(1, ceil(count(*)::numeric / greatest(p_per_shard, 1)))::int as shards
      from plants.logins
     where status = 'ok'
  )
  select s.i, n.shards, (s.i % 3) * 10000
    from n, generate_series(0, n.shards - 1) as s(i)
$function$;
