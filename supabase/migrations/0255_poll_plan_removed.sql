-- SOLAR-650: Part B (0253, the minute plan sent in 5-second slots) removed.
-- Live 2026-11-24 16:23-19:27 UTC, then back on the old path. Tests that day: pg_net sends in
-- batches and waits for each batch to finish, so a shard posted at 5 s waited for the 0 s ones;
-- with a slow SunSynk, shards arrived over 55 s late and were refused. At 1,000 logins the old
-- path lost fewer readings. The redesign is its own ticket (poller v3).
-- Kept: the seats_account index (billing reads seats by account on its own).
-- Restored as before 0253: the sunsynk-poll command (0181), private.poll_shards (0030) and
-- private.fn_call_states (0181).

-- Cron first: sunsynk-poll still calls poll_minute_mode(), dropped below.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - no cron jobs to change (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'poll-tick') then
    perform cron.unschedule('poll-tick');
  end if;
  if exists (select 1 from cron.job where jobname = 'sunsynk-poll') then
    perform cron.alter_job(job_id := (select jobid from cron.job where jobname = 'sunsynk-poll'),
      command := $c$select private.call_fn('poll', jsonb_build_object('shard', s.shard, 'shards', s.shards, 'delay_ms', s.delay_ms), 55000) from private.poll_shards() s$c$);
  end if;
end $$;

create or replace function private.poll_shards(p_per_shard int default 10)
returns table (shard int, shards int, delay_ms int)
language sql
stable
set search_path = pg_temp
as $$
  with n as (
    select greatest(1, ceil(count(*)::numeric / greatest(p_per_shard, 1)))::int as shards
      from private.sunsynk_accounts
     where status = 'active'
  )
  select s.i, n.shards, (s.i % 3) * 10000
    from n, generate_series(0, n.shards - 1) as s(i)
$$;

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

drop function private.poll_tick();
drop function private.poll_plan_check(timestamptz);
drop function public.poll_plan_jobs(bigint, int);
drop function private.poll_minute_mode();
drop function private.poll_plan_build(timestamptz);
drop table private.poll_plan;
drop table private.poll_plan_shards;
drop table private.poll_plan_diffs;
drop table private.poll_plan_minutes;
drop table private.poll_mode;
