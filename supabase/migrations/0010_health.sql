-- ============================================================================
-- Liveness probe for external monitoring.
--
-- The one function on this project callable WITHOUT a session, so deliberately
-- minimal: how long since the last logged minute, and nothing else. No power
-- figures, no SOC, no per-inverter detail — load curves reveal when the house is
-- empty, and none of that is needed to answer "is it still logging?".
--
-- Everything else stays authenticated-only. If this ever needs to return more,
-- it should stop being anon-callable instead.
-- ============================================================================

create or replace function public.api_health()
returns jsonb
language sql
stable
security definer          -- reads agg_minute, which anon has no grant on
set search_path = public, pg_temp
as $$
  with s as (
    select max(ts) as last_ts from public.agg_minute
  )
  select jsonb_build_object(
    'lastTs', s.last_ts,
    'ageSeconds', case when s.last_ts is null then null
                       else extract(epoch from now())::bigint - s.last_ts end,
    -- the poller runs every minute; 15 min of silence means something is wrong
    -- (function erroring, cron unscheduled, Vault secret rotated, project paused)
    'stale', s.last_ts is null
             or (extract(epoch from now())::bigint - s.last_ts) > 900,
    'expectedIntervalSeconds', 60)
  from s
$$;

revoke all on function public.api_health() from public;
grant execute on function public.api_health() to anon, authenticated, service_role;
