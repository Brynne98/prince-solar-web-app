-- ============================================================================
-- Cache the clear-sky calibration.
--
-- solar_scale_w() derived the scale from every un-curtailed sample ever logged —
-- ~12k rows, ~25k clear_sky_shape() evaluations, ~99k cfg() lookups — on EVERY
-- call. That is 2.6 s on a fast laptop and considerably worse on shared compute,
-- so /api/trends/potential exceeded the statement timeout in production and the
-- dotted potential line silently vanished (the frontend catches and renders
-- nothing).
--
-- The monolith cached this for 6 h (server.js solarCal); the port dropped that.
-- Restored here as a table refreshed on a schedule, matching how everything else
-- works: scheduled writers, cheap reads. The value moves slowly — it is a
-- percentile over months of samples — so a daily refresh is more than enough.
-- ============================================================================

create table if not exists public.solar_cal (
  id          int primary key default 1 check (id = 1),
  scale_w     integer,
  samples     integer,
  computed_at timestamptz
);
insert into public.solar_cal (id) values (1) on conflict do nothing;

-- The expensive calculation, now run on a schedule rather than per request.
-- VOLATILE (it writes), service_role only.
create or replace function public.q_recompute_solar_scale()
returns jsonb
language plpgsql
as $$
declare n int; picked double precision; result integer;
begin
  create temp table if not exists _ratios (r double precision) on commit drop;
  delete from _ratios;

  -- one clear_sky_shape() call per sample instead of two
  insert into _ratios
  select pv_w / shape from (
    select c.pv_w, public.clear_sky_shape(c.ts) as shape from public.q_cal_samples() c
  ) s where shape > 0.25;

  select count(*) into n from _ratios;
  if n >= 20 then
    -- same index arithmetic as the JS: sorted[floor(n * percentile)]
    select r into picked from _ratios
     order by r offset (floor(n * public.cfg('SOLAR_CAL_PERCENTILE')))::int limit 1;
  end if;

  -- fallback until there are enough samples, then cap at CAP_MULT x nameplate
  result := round(least(
    coalesce(picked, public.cfg('SYSTEM_KWP') * 1000 * 0.82),
    public.cfg('SYSTEM_KWP') * 1000 * public.cfg('SOLAR_CAL_CAP_MULT')))::int;

  update public.solar_cal
     set scale_w = result, samples = n, computed_at = now()
   where id = 1;

  return jsonb_build_object('scaleW', result, 'samples', n);
end $$;

-- Now a cache read. Falls back to the nameplate default if the cache has never
-- been populated, so a fresh project still draws a sensible line.
create or replace function public.solar_scale_w()
returns integer language sql stable as $$
  select coalesce(
    (select scale_w from public.solar_cal where id = 1),
    round(public.cfg('SYSTEM_KWP') * 1000 * 0.82)::int)
$$;

alter table public.solar_cal enable row level security;
drop policy if exists solar_cal_read on public.solar_cal;
create policy solar_cal_read on public.solar_cal for select to authenticated using (true);
revoke all on public.solar_cal from anon;
grant select on public.solar_cal to authenticated;
grant select, insert, update on public.solar_cal to service_role;

revoke all on function public.q_recompute_solar_scale() from public, anon, authenticated;
grant execute on function public.q_recompute_solar_scale() to service_role;

-- Populate immediately so the line appears without waiting for the first cron run.
select public.q_recompute_solar_scale();

-- ---------------------------------------------------------------------------
-- Refresh daily. Pure SQL, so this needs no Edge Function round trip — unlike the
-- jobs in 0009 it also needs no Vault secret. Same guard as 0009: a no-op wherever
-- pg_cron isn't enabled, which keeps the local stack clean.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping solar-cal schedule (expected locally)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'sunsynk-solar-cal') then
    perform cron.unschedule('sunsynk-solar-cal');
  end if;
  -- 02:40 UTC, after sync-plant-energy at 02:15 and clear of the busy hours
  perform cron.schedule('sunsynk-solar-cal', '40 2 * * *',
    'select public.q_recompute_solar_scale();');
  raise notice 'scheduled sunsynk-solar-cal';
end $$;
