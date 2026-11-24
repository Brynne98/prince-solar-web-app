-- SOLAR-650 Part A: a run log for the poll shards, kept 7 days.
-- private.sunsynk_calls (0178) keeps daily totals per shard, so no single run can be timed
-- from it. One row per minute and shard, written once by the shard at the end of its run
-- (an empty shard too; a one-login Check run is not logged). Times as the shard saw them:
-- scheduled = the minute plus the delay the cron job gave it, started = after that delay,
-- before the job query, jobs_read = the job query answered, finished = all logins done.
-- logins: one entry per login, [{account, commit_ms, plants, inverters, error}], commit_ms
-- = ms after the minute that poll_commit_v2 answered (null when nothing was committed).
-- plants = plants the shard was given; inverters = inverters read. error = the run's own
-- failure, or how many logins failed. Later shard sizing (Part B) is measured from here.

create table private.poll_runs (
  minute       timestamptz not null,
  shard        int         not null,
  shards       int         not null,
  scheduled_at timestamptz not null,
  started_at   timestamptz not null,
  jobs_read_at timestamptz,
  finished_at  timestamptz not null,
  plants       int         not null default 0,
  inverters    int         not null default 0,
  logins       jsonb       not null default '[]',
  error        text,
  primary key (minute, shard)
);
alter table private.poll_runs enable row level security;

-- A repeat of the same minute and shard (a retried or hand-sent call) replaces the row.
-- Shard 0 deletes rows older than 7 days on the hour.
create or replace function public.poll_run_log(p jsonb)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
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
end $$;
revoke all on function public.poll_run_log(jsonb) from public, anon, authenticated;
grant execute on function public.poll_run_log(jsonb) to service_role;
