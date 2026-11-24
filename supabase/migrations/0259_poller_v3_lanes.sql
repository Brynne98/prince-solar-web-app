-- ============================================================================
-- 0259 — poller v3 stage 1: edge lanes (SOLAR-656; design reports/poller-v3-design.md,
-- sections 5 and 7).
--
--   private.poll_mode           which path reads each minute: 'edge' (today's poll shards)
--                               or 'lanes' (K poll-lane calls, each reading its seconds all
--                               minute). One row; a missing row reads as 'edge'.
--   cron sunsynk-poll           today's command, only while the mode is 'edge'.
--   cron poll-lanes             posts K lanes while the mode is 'lanes'. Plain SQL.
--   cron poll-share-retry,      the chores shard 0 of `poll` did (share login retry, the
--   poll-calls-report,          daily SunSynk call report to PostHog, poll_runs pruning), now
--   poll-runs-prune             their own jobs, so they run whichever path reads.
--   poll_run_log                0251 without the pruning.
--   poll_lane_routes(seconds)   poll_routes (0258) plus the login (token, user) and `lead`:
--                               the read of a login that refreshes its inverter list and
--                               plants (the login's lowest plant id, when it is read plant
--                               by plant on several seconds).
--   inverters_cached_many       inverters_cached (0230) for many logins in one query, for
--                               some plants only; inverters_cached now calls it.
--   job_check_inputs            0234 with 'shards' = the lanes while the mode is 'lanes'.
--
-- Switching: update private.poll_mode set mode = 'lanes' (or 'edge'). It takes effect at
-- the next minute: both cron jobs read it when they fire.
-- ============================================================================

create table private.poll_mode (
  id         boolean primary key default true check (id),
  mode       text not null default 'edge' check (mode in ('edge', 'lanes')),
  lanes      int not null default 4 check (lanes between 1 and 60),
  changed_at timestamptz not null default now()
);
alter table private.poll_mode enable row level security;
insert into private.poll_mode default values;

create or replace function public.poll_run_log(p jsonb)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  insert into private.poll_runs as r
         (minute, shard, shards, scheduled_at, started_at, jobs_read_at, finished_at,
          plants, inverters, logins, error)
  values (to_timestamp((p->>'ts')::bigint), (p->>'shard')::int, coalesce((p->>'shards')::int, 1),
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
end $$;

-- ---------------------------------------------------------------------------
-- inverters_cached for many logins. Same rows as inverters_cached(login) per login, with
-- the login's id first; p_plants (null = all) keeps the inverters of those plants only.
-- ---------------------------------------------------------------------------
create function public.inverters_cached_many(p_accounts uuid[], p_plants bigint[] default null)
returns table(account_id uuid, sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text, gsn text,
              comm_type text, plant_name text, ord integer, status integer, last_reading jsonb, carried_run integer,
              upload_s integer)
language plpgsql
security definer
set search_path = private, pg_temp
as $$
#variable_conflict use_column
declare
  -- a variable, not now() in the query, so the planner opens 2 partitions, not all
  v_floor bigint := extract(epoch from now())::bigint - 86400;
begin
  return query
  select a.id, i.sn, i.plant_id, m.alias, m.model, m.soft_ver, m.hmi_ver,
         m.gsn, m.comm_type, m.plant_name, m.ord, m.status,
         lr.row as last_reading,
         coalesce(cr.n, 0)::integer as carried_run,
         ug.s as upload_s
    from unnest(p_accounts) a(id)
    join private.inverters i
      on (i.account_id = a.id
          or i.plant_id in (select pu.plant_id from public.plant_users pu where pu.account_id = a.id))
     and (p_plants is null or i.plant_id = any (p_plants))
    left join private.meta m on m.sn = i.sn
    left join lateral (
      select to_jsonb(r) as row
        from public.readings r
       where r.sn = i.sn and r.ts > v_floor
       order by r.ts desc
       limit 1) lr on true
    left join lateral (
      select count(*) as n
        from public.readings r
       where r.sn = i.sn and r.ts > v_floor
         and r.ts > coalesce((select max(r2.ts) from public.readings r2
                               where r2.sn = i.sn and r2.ts > v_floor and not r2.carried), 0)) cr on true
    left join lateral (
      select min(g.gap)::integer as s
        from (select extract(epoch from (d.dt - lead(d.dt) over (order by d.dt desc))) as gap
                from (select distinct t.device_time::timestamp as dt
                        from (select r.device_time
                                from public.readings r
                               where r.sn = i.sn and r.ts > v_floor
                               order by r.ts desc
                               limit 20) t
                       where t.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
                       order by 1 desc
                       limit 3) d) g
       where g.gap is not null
      having count(*) = 2) ug on true
   order by a.id, coalesce(m.ord, 9999), i.sn;
end $$;

create or replace function public.inverters_cached(p_account uuid)
returns table(sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text, gsn text, comm_type text, plant_name text, ord integer, status integer, last_reading jsonb, carried_run integer, upload_s integer)
language sql
security definer
set search_path = private, pg_temp
as $$
  select c.sn, c.plant_id, c.alias, c.model, c.soft_ver, c.hmi_ver, c.gsn, c.comm_type, c.plant_name, c.ord, c.status,
         c.last_reading, c.carried_run, c.upload_s
    from public.inverters_cached_many(array[p_account]) c
$$;

-- ---------------------------------------------------------------------------
-- The routes read on these seconds with their logins. lead: this plant is its login's
-- lowest plant id among every plant read this minute (on any second).
-- ---------------------------------------------------------------------------
create function public.poll_lane_routes(p_seconds int[], p_at timestamptz default now())
returns table (plant_id bigint, account_id uuid, plant_version bigint, timezone text,
               batt_positive_means text, has_grid boolean, ends_at timestamptz, read_second int,
               user_id uuid, sunsynk_username text, access_token text, access_expires_at bigint, lead boolean)
language sql stable security definer set search_path = public, private, pg_temp as $$
  select r.plant_id, r.account_id, r.plant_version, r.timezone, r.batt_positive_means, r.has_grid, r.ends_at,
         r.read_second, sa.user_id, sa.sunsynk_username, sa.access_token, sa.access_expires_at, r.lead
    from (select pr.*, pr.plant_id = min(pr.plant_id) over (partition by pr.account_id) as lead
            from public.poll_routes(array(select generate_series(0, 59)), p_at) pr) r
    join private.sunsynk_accounts sa on sa.id = r.account_id
   where r.read_second = any (p_seconds)
   order by r.read_second, r.account_id, r.plant_id
$$;

-- ---------------------------------------------------------------------------
-- job_check_inputs: 0234, with only the lines marked 0259 changed.
-- ---------------------------------------------------------------------------
create or replace function public.job_check_inputs()
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  d    date := (now() at time zone 'Africa/Johannesburg')::date;
  m    private.job_check_mark;
  c    bigint; f bigint;
  jobs jsonb := '[]';
  fn_calls_state jsonb := '[]';
begin
  select coalesce(sum(calls), 0),
         coalesce(sum(calls) filter (where result in ('429', '403_throttle', '5xx', 'network', 'timeout')), 0)
    into c, f
    from private.sunsynk_calls where day = d and kind <> 'poll_run';
  select * into m from private.job_check_mark for update;
  insert into private.job_check_mark as t values (true, now(), d, c, f)
    on conflict (id) do update set at = excluded.at, day = excluded.day, calls = excluded.calls, failed = excluded.failed;

  if to_regclass('cron.job') is not null then
    with starts as (                                                     -- 0234
      select r.jobid, max(r.start_time) as last_start from cron.job_run_details r group by r.jobid
    ), ends as (                                                         -- 0234
      select distinct on (r.jobid) r.jobid, r.status, r.end_time, r.return_message
        from cron.job_run_details r
       where r.status in ('succeeded', 'failed')
       order by r.jobid, r.start_time desc
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'job', j.jobname, 'schedule', j.schedule, 'active', j.active,
             'last_start', s.last_start,                                 -- 0234
             'last_status', l.status,
             'last_end', l.end_time,
             'message', left(regexp_replace(coalesce(l.return_message, ''), '[^\s"''<>@]+@[^\s"''<>@]+\.[a-z]{2,}', '[email]', 'gi'), 200))
             order by j.jobname), '[]')
      into jobs
      from cron.job j
      left join starts s on s.jobid = j.jobid                            -- 0234
      left join ends l on l.jobid = j.jobid;                             -- 0234
  end if;

  delete from private.fn_calls where at < now() - interval '2 days';
  if to_regclass('net._http_response') is not null then
    fn_calls_state := private.fn_call_states();
  end if;

  return jsonb_build_object(
    'now', now(),
    'shards', (select coalesce(jsonb_agg(jsonb_build_object('shard', s.shard,
                 'last_at', (select max(last_at) from private.sunsynk_calls k
                              where k.kind = 'poll_run' and k.result = 's' || s.shard and k.day >= d - 1))
                 order by s.shard), '[]')
                 from (select s.shard from private.poll_shards() s                                  -- 0259
                        where coalesce((select pm.mode from private.poll_mode pm), 'edge') = 'edge'
                       union all
                       select l from private.poll_mode pm, generate_series(0, pm.lanes - 1) l       -- 0259
                        where pm.mode = 'lanes') s),
    'jobs', jobs,
    'calls', fn_calls_state,
    'sunsynk', jsonb_build_object(
      'calls', case when m.day = d then c - m.calls else c end,
      'failed', case when m.day = d then f - m.failed else f end,
      'since', m.at),
    'email', (select jsonb_build_object('waiting', count(*), 'oldest_due', min(due_at))
                from public.email_queue where status = 'queued' and due_at <= now() - interval '10 minutes'),
    'checks', (select coalesce(jsonb_object_agg(name, jsonb_build_object('failing', failing, 'since', since)), '{}')
                 from private.job_checks));
end $$;
revoke all on function public.job_check_inputs() from public, anon, authenticated;

revoke all on function public.inverters_cached_many(uuid[], bigint[]) from public, anon, authenticated;
revoke all on function public.poll_lane_routes(int[], timestamptz) from public, anon, authenticated;
grant execute on function public.inverters_cached_many(uuid[], bigint[]) to service_role;
grant execute on function public.poll_lane_routes(int[], timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- Cron. sunsynk-poll keeps 0181's command, read only while the mode is 'edge'. poll-lanes
-- posts the lanes in one pg_net batch while it is 'lanes'. The chores call poll-lane.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not enabled here - no cron jobs to change (expected on the local stack)';
    return;
  end if;
  perform cron.alter_job(job_id := (select jobid from cron.job where jobname = 'sunsynk-poll'),
    command := $c$select private.call_fn('poll', jsonb_build_object('shard', s.shard, 'shards', s.shards, 'delay_ms', s.delay_ms), 55000) from private.poll_shards() s where coalesce((select mode from private.poll_mode), 'edge') = 'edge'$c$)
   where exists (select 1 from cron.job where jobname = 'sunsynk-poll');
  perform cron.schedule('poll-lanes', '* * * * *',
    $c$select private.call_fn('poll-lane', jsonb_build_object('lane', l, 'lanes', m.lanes, 'ts', extract(epoch from date_trunc('minute', now()))::bigint), 55000) from private.poll_mode m, generate_series(0, m.lanes - 1) l where m.mode = 'lanes'$c$);
  perform cron.schedule('poll-share-retry', '* * * * *',
    $c$select private.call_fn('poll-lane', '{"chore": "share_retry"}', 55000)$c$);
  -- 00:05, 00:10 and 00:15 SA time: yesterday's SunSynk calls to PostHog (repeats cover a failed send)
  perform cron.schedule('poll-calls-report', '5,10,15 22 * * *',
    $c$select private.call_fn('poll-lane', '{"chore": "calls_report"}', 55000)$c$);
  perform cron.schedule('poll-runs-prune', '3 * * * *',
    $c$delete from private.poll_runs where minute < now() - interval '7 days'$c$);
end $$;

notify pgrst, 'reload schema';
