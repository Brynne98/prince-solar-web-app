-- ============================================================================
-- 0234 — job_check_inputs reads the cron log twice, not twice per job (SOLAR-422).
--
-- Review K item 1: for each of the 18 cron jobs, job_check_inputs() ran two
-- lookups on cron.job_run_details (last start, last finished run). That table
-- has no index but runid, and it belongs to supabase_admin, so we can't add one.
-- Each lookup was a full scan: 36 scans of ~32,000 rows every 5 minutes,
-- 118,104 scans and 3.9 billion rows read from 15 Oct to 22 Nov, mean 311 ms.
-- Now one grouped pass finds the last start per job and one the last finished
-- run per job. Same output.
--
-- Body: job_check_inputs 0181, with only the lines marked 0234 changed. No rows are written.
-- ============================================================================

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
