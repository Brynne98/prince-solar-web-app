-- ============================================================================
-- 0228 — api_health with no plant answers only up or down (SOLAR-530).
--
-- anon keeps execute (0026) for .github/workflows/health.yml, which calls it
-- signed out. That call returned lastTs and ageSeconds: the newest reading time
-- across all plants. ageSeconds gives the same time back (now - age), so both go.
-- Nothing reads them: the app never calls /api/health, job-check and the `health`
-- function use uptime_health, and no database function calls api_health now.
-- With a plant, the owner still gets the full answer; my_plant() checks the link
-- and needs a session, so anon can't use that path.
-- ============================================================================
create or replace function public.api_health(p_plant bigint default null)
returns jsonb
language sql
stable security definer
set search_path = public, pg_temp
as $$
  with s as (
    select max(ts) as last_ts from public.agg_minute
     where p_plant is null or plant_id = public.my_plant(p_plant)
  ),
  a as (
    select s.last_ts,
           s.last_ts is null
           or (extract(epoch from now())::bigint - s.last_ts) > 900 as stale
      from s
  )
  select case when p_plant is null
    then jsonb_build_object('stale', a.stale)
    else jsonb_build_object(
      'lastTs', a.last_ts,
      'ageSeconds', case when a.last_ts is null then null
                         else extract(epoch from now())::bigint - a.last_ts end,
      'stale', a.stale,
      'expectedIntervalSeconds', 60,
      'scope', 'plant')
  end
  from a
$$;

revoke all on function public.api_health(bigint) from public;
grant execute on function public.api_health(bigint) to anon, authenticated, service_role;
