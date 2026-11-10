-- SOLAR-468: count SunSynk calls per day.
-- apiGet (_shared/sunsynk.ts) keeps counts in memory; each function adds them here in one
-- write (poll once per run). One row per SA day, data type and result: calls, total ms,
-- slowest ms. Each poll run also adds a row of kind 'poll_run', result = its shard ('s0',
-- 's1', ...): runs, run time, plants polled and when it last ran (a cheap "poll ran"
-- signal for SOLAR-428). Rows are kept 400 days.

create table private.sunsynk_calls (
  day      date   not null,
  kind     text   not null,
  result   text   not null,
  calls    bigint not null default 0,
  ms_total bigint not null default 0,
  ms_max   int    not null default 0,
  plants   bigint not null default 0,
  last_at  timestamptz,
  primary key (day, kind, result)
);
alter table private.sunsynk_calls enable row level security;

-- p_rows: [{kind, result, calls, ms, ms_max}], one per data type and result seen this run.
-- A poll run also goes in as kind 'poll_run' with p_shard, p_run_ms and p_plants; other
-- functions pass p_shard null.
create or replace function public.sunsynk_tally(p_rows jsonb, p_shard int, p_run_ms int, p_plants int)
returns void language sql security definer set search_path = public, private, pg_temp as $$
  insert into private.sunsynk_calls as t (day, kind, result, calls, ms_total, ms_max, plants, last_at)
  select (now() at time zone 'Africa/Johannesburg')::date, r.kind, r.result, r.calls, r.ms, r.ms_max, 0, now()
    from jsonb_to_recordset(coalesce(p_rows, '[]')) as r(kind text, result text, calls bigint, ms bigint, ms_max int)
   where r.kind is not null and r.result is not null
  union all
  select (now() at time zone 'Africa/Johannesburg')::date, 'poll_run', 's' || p_shard, 1, p_run_ms, p_run_ms, p_plants, now()
   where p_shard is not null
  on conflict (day, kind, result) do update set
    calls    = t.calls + excluded.calls,
    ms_total = t.ms_total + excluded.ms_total,
    ms_max   = greatest(t.ms_max, excluded.ms_max),
    plants   = t.plants + excluded.plants,
    last_at  = excluded.last_at;
$$;
revoke all on function public.sunsynk_tally(jsonb, int, int, int) from public, anon, authenticated;
grant execute on function public.sunsynk_tally(jsonb, int, int, int) to service_role;

-- Yesterday's totals, null when nothing was counted. Failed = refused or unanswered (429,
-- throttle 403, 5xx, network, timeout); a 401 retried after a token refresh is not. Calls per
-- plant divides by plants per minute (each shard's plants over its run count, summed).
create or replace function public.sunsynk_calls_report()
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  d date := (now() at time zone 'Africa/Johannesburg')::date - 1;
  out jsonb;
begin
  delete from private.sunsynk_calls where day < d - 400;
  if not exists (select 1 from private.sunsynk_calls where day = d) then return null; end if;

  with c as (select * from private.sunsynk_calls where day = d and kind <> 'poll_run'),
       r as (select * from private.sunsynk_calls where day = d and kind = 'poll_run'),
       tot as (
         select coalesce(sum(calls), 0) as calls,
                coalesce(sum(calls) filter (where result in ('429', '403_throttle', '5xx', 'network', 'timeout')), 0) as failed,
                coalesce(sum(ms_total), 0) as ms
           from c),
       pl as (select coalesce(sum(plants::numeric / nullif(calls, 0)), 0) as plants,
                     coalesce(sum(calls), 0) as runs,
                     coalesce(max(ms_max), 0) as slowest_ms
                from r)
  select jsonb_build_object(
           'day', d,
           'calls', tot.calls,
           'failed', tot.failed,
           'error_rate', round(tot.failed::numeric / nullif(tot.calls, 0), 4),
           'avg_call_ms', round(tot.ms::numeric / nullif(tot.calls, 0)),
           'plants', round(pl.plants, 1),
           'calls_per_plant', round(tot.calls / nullif(pl.plants, 0)),
           'poll_runs', pl.runs,
           'slowest_run_ms', pl.slowest_ms,
           'by_result', (select coalesce(jsonb_object_agg(result, n), '{}') from
                           (select result, sum(calls) as n from c group by result) x),
           'by_kind', (select coalesce(jsonb_object_agg(kind, n), '{}') from
                         (select kind, sum(calls) as n from c group by kind) y))
    into out
    from tot, pl;
  return out;
end $$;
revoke all on function public.sunsynk_calls_report() from public, anon, authenticated;
grant execute on function public.sunsynk_calls_report() to service_role;
