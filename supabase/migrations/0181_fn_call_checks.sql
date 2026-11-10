-- SOLAR-472 C: a timed call to a function that fails or times out. pg_cron starts poll,
-- notify, billing, recover, sync-plant-energy and job-check with net.http_post, which only
-- queues the call, so cron.job_run_details says succeeded whatever the function answers.
-- Each of those jobs now calls private.call_fn(), which queues the same call and keeps its
-- request id and function name in private.fn_calls. pg_net writes the answer to
-- net._http_response under the same id (kept about 6 hours). job_check_inputs() joins
-- the two, and job-check flags call:<fn> while the last answered call to <fn> failed:
-- not 2xx, timed out, a pg_net error, or no answer 2 minutes past its timeout.
--
-- SOLAR-469 A: uptime_health() for the health function an outside uptime service calls.

create table private.fn_calls (
  id         bigint primary key,       -- pg_net request id = net._http_response.id
  fn         text not null,
  shard      int,
  at         timestamptz not null default now(),
  timeout_ms int not null
);
alter table private.fn_calls enable row level security;
create index on private.fn_calls (fn, at desc);

create or replace function private.call_fn(p_path text, p_body jsonb default '{}', p_timeout_ms int default 55000)
returns bigint language plpgsql security definer set search_path = public, private, pg_temp as $$
declare rid bigint;
begin
  rid := net.http_post(
    url := 'https://pmakzojwhouamawgszrc.functions.supabase.co/' || p_path,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
      'Content-Type', 'application/json'),
    body := p_body,
    timeout_milliseconds := p_timeout_ms);
  insert into private.fn_calls (id, fn, shard, timeout_ms)
  values (rid, split_part(split_part(p_path, '?', 1), '/', 1), (p_body ->> 'shard')::int, p_timeout_ms)
  on conflict (id) do nothing;
  return rid;
end $$;
revoke all on function private.call_fn(text, jsonb, int) from public, anon, authenticated;

-- Per function called in the last 2 days: the outcome of the last answered call per shard
-- in the last 5 hours (answers older than that may be gone from net._http_response).
-- failing is null when no call has an outcome yet, so a daily job keeps its state.
create or replace function private.fn_call_states()
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
begin
  -- plpgsql, not sql: net._http_response is missing on the local stack, and a sql body is
  -- checked when it is created.
  return (with c as (
    select f.fn, f.shard, f.at, f.id, f.timeout_ms,
           r.id is not null as answered,
           case when r.id is null then 'no answer'
                when r.timed_out then 'timeout'
                when r.error_msg is not null then 'error'
                when r.status_code between 200 and 299 then null
                else r.status_code::text end as bad,
           left(coalesce(r.error_msg, ''), 200) as error
      from private.fn_calls f
      left join net._http_response r on r.id = f.id
     where f.at > now() - interval '5 hours'
  ), last as (
    select distinct on (fn, shard) *
      from c
     where answered or at < now() - timeout_ms * interval '1 millisecond' - interval '2 minutes'
     order by fn, shard, at desc
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'fn', fns.fn,
           'failing', (select bool_or(l.bad is not null) from last l where l.fn = fns.fn),
           'result', (select string_agg(distinct l.bad, ',') from last l where l.fn = fns.fn),
           'error', (select max(nullif(l.error, '')) from last l where l.fn = fns.fn and l.bad is not null),
           'last_call', (select max(l.at) from last l where l.fn = fns.fn),
           'failed_1h', (select count(*) from c where c.fn = fns.fn and c.bad is not null and c.answered
                                                  and c.at > now() - interval '1 hour'))
           order by fns.fn), '[]')
    from (select distinct fn from private.fn_calls where at > now() - interval '2 days') fns);
end $$;
revoke all on function private.fn_call_states() from public, anon, authenticated;

-- 0180's job_check_inputs() plus 'calls', and trims fn_calls to 2 days.
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
    select coalesce(jsonb_agg(jsonb_build_object(
             'job', j.jobname, 'schedule', j.schedule, 'active', j.active,
             'last_start', (select max(start_time) from cron.job_run_details r where r.jobid = j.jobid),
             'last_status', l.status,
             'last_end', l.end_time,
             'message', left(regexp_replace(coalesce(l.return_message, ''), '[^\s"''<>@]+@[^\s"''<>@]+\.[a-z]{2,}', '[email]', 'gi'), 200))
             order by j.jobname), '[]')
      into jobs
      from cron.job j
      left join lateral (select status, end_time, return_message from cron.job_run_details r
                          where r.jobid = j.jobid and r.status in ('succeeded', 'failed')
                          order by r.start_time desc limit 1) l on true;
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
                 from private.poll_shards() s),
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
grant execute on function public.job_check_inputs() to service_role;

-- SOLAR-469 A: minutes since job-check last read its inputs (it moves job_check_mark each
-- run). The health function answers 503 past 15; a database it can't reach is a 503 too.
create or replace function public.uptime_health()
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object('job_check_minutes',
           (select floor(extract(epoch from now() - at) / 60)::int from private.job_check_mark));
$$;
revoke all on function public.uptime_health() from public, anon, authenticated;
grant execute on function public.uptime_health() to service_role;

-- The six HTTP jobs go through call_fn. Same schedules, bodies and timeouts as before.
do $$
declare
  j record;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not enabled here - skipping call_fn jobs (expected on the local stack)';
    return;
  end if;
  for j in select * from (values
      ('sunsynk-poll', $c$select private.call_fn('poll', jsonb_build_object('shard', s.shard, 'shards', s.shards, 'delay_ms', s.delay_ms), 55000) from private.poll_shards() s$c$),
      ('email-notify', $c$select private.call_fn('notify', '{}', 55000)$c$),
      ('billing-run', $c$select private.call_fn('billing/run', '{}', 120000)$c$),
      ('sunsynk-recover', $c$select private.call_fn('recover', '{}', 150000)$c$),
      ('sunsynk-plant-energy', $c$select private.call_fn('sync-plant-energy', '{}', 150000)$c$),
      ('job-check', $c$select private.call_fn('job-check', '{}', 30000)$c$)
    ) as v(name, command)
  loop
    perform cron.alter_job(job_id := (select jobid from cron.job where jobname = j.name), command := j.command)
      where exists (select 1 from cron.job where jobname = j.name);
  end loop;
end $$;

notify pgrst, 'reload schema';
