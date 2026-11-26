CREATE OR REPLACE FUNCTION public.poll_run_log(p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  m timestamptz := to_timestamp((p->>'ts')::bigint);
  s int := (p->>'shard')::int;
begin
  insert into private.poll_runs as r
         (minute, shard, shards, scheduled_at, started_at, jobs_read_at, finished_at,
          plants, inverters, logins, error)
  values (m, s, coalesce((p->>'shards')::int, 1),
          to_timestamp((p->>'scheduled_ms')::bigint / 1000.0),
          to_timestamp((p->>'started_ms')::bigint / 1000.0),
          to_timestamp((p->>'jobs_read_ms')::bigint / 1000.0),
          to_timestamp((p->>'finished_ms')::bigint / 1000.0),
          coalesce((p->>'plants')::int, 0), coalesce((p->>'inverters')::int, 0),
          coalesce(p->'logins', '[]'), left(p->>'error', 500))
  on conflict (minute, shard) do update set
    shards = excluded.shards, scheduled_at = excluded.scheduled_at,
    started_at = excluded.started_at, jobs_read_at = excluded.jobs_read_at,
    finished_at = excluded.finished_at, plants = excluded.plants,
    inverters = excluded.inverters, logins = excluded.logins, error = excluded.error;

  if s = 0 and extract(minute from m) = 0 then
    delete from private.poll_runs where minute < m - interval '7 days';
  end if;
end $function$;
