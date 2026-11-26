CREATE OR REPLACE FUNCTION public.sunsynk_calls_report()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
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
end $function$;
