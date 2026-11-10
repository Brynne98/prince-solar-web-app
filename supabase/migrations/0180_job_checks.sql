-- SOLAR-428: checks that the timed jobs ran. Every 5 minutes pg_cron calls the job-check
-- function, which reads job_check_inputs(), judges each check, saves what changed with
-- job_check_save() and sends PostHog job_check_failed / job_check_recovered (distinct id
-- edge:<job>). A PostHog alert on job_check_failed emails admin@. Checks:
--   poll:s<n>    a poll shard that private.poll_shards() expects has not logged a run
--                (sunsynk_calls kind poll_run, 0178) in 5 min.
--   cron:<job>   the job's last finished run failed, or a run its schedule asked for did
--                not start (the schedule is read in the function). Jobs that only queue an
--                HTTP call (poll, notify, billing, recover) always show success here; the
--                poll and email checks cover what they leave behind.
--   sunsynk      20% or more of at least 20 SunSynk calls since the last check failed
--                (429, throttle 403, 5xx, network, timeout); clears under 10%.
--   email-queue  an email due 10 min ago or more is still queued.

create table private.job_checks (
  name    text primary key,
  failing boolean not null default false,
  since   timestamptz not null default now(),
  detail  jsonb
);
alter table private.job_checks enable row level security;

-- Today's SunSynk counts at the last check, so the next one can take the difference.
create table private.job_check_mark (
  id     boolean primary key default true check (id),
  at     timestamptz not null,
  day    date not null,
  calls  bigint not null,
  failed bigint not null
);
alter table private.job_check_mark enable row level security;

-- Everything the check judges, and moves the SunSynk mark on. Cron messages are cut to
-- 200 characters with email addresses masked.
create or replace function public.job_check_inputs()
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  d    date := (now() at time zone 'Africa/Johannesburg')::date;
  m    private.job_check_mark;
  c    bigint; f bigint;
  jobs jsonb := '[]';
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

  return jsonb_build_object(
    'now', now(),
    'shards', (select coalesce(jsonb_agg(jsonb_build_object('shard', s.shard,
                 'last_at', (select max(last_at) from private.sunsynk_calls k
                              where k.kind = 'poll_run' and k.result = 's' || s.shard and k.day >= d - 1))
                 order by s.shard), '[]')
                 from private.poll_shards() s),
    'jobs', jobs,
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

-- p_changes: [{name, failing, detail}], only checks whose state flipped. A check seen for
-- the first time and passing is not stored.
create or replace function public.job_check_save(p_changes jsonb)
returns void language sql security definer set search_path = public, private, pg_temp as $$
  insert into private.job_checks as t (name, failing, since, detail)
  select x.name, x.failing, now(), x.detail
    from jsonb_to_recordset(coalesce(p_changes, '[]')) as x(name text, failing boolean, detail jsonb)
   where x.name is not null and x.failing is not null
  on conflict (name) do update set failing = excluded.failing, since = excluded.since, detail = excluded.detail;
$$;
revoke all on function public.job_check_save(jsonb) from public, anon, authenticated;
grant execute on function public.job_check_save(jsonb) to service_role;

-- Every 5 minutes, 2 min past so it reads after poll's minute. Production only, as 0092.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not enabled here - skipping job-check schedule (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'job-check') then
    perform cron.unschedule('job-check');
  end if;
  perform cron.schedule('job-check', '2-59/5 * * * *', $job$
    select net.http_post(
      url := 'https://pmakzojwhouamawgszrc.functions.supabase.co/job-check',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
        'Content-Type', 'application/json'),
      body := '{}'::jsonb,
      timeout_milliseconds := 30000);
  $job$);
end $$;

notify pgrst, 'reload schema';
