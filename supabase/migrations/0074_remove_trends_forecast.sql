-- ============================================================================
-- 0074 — remove the Trends page's own RPCs and the solar forecast
-- (SOLAR-47, SOLAR-64).
--
-- Back to basics (Brynne, 2026-10-05): the app is Live, Solar, Grid and
-- Equipment. Trends is removed from the frontend (TRENDS.md records what it
-- had), and the forecast only fed its dotted "Expected" line.
--
-- Dropped: api_trends_segments and q_segment_power, api_trends_monthly (Trends
-- only); the sunsynk-forecast and sunsynk-forecast-cal jobs; solar_forecast,
-- solar_forecast_cal and every function that only they used (api_forecast,
-- q_forecast_cal_days, q_forecast_cal_samples, q_cal_samples, forecast_k,
-- forecast_k_day). api_trends_daily keeps its rows (Solar's 30-day bars) and
-- loses the Expected field.
--
-- Kept: api_trends_by_hour (Live's typical charge, Battery's "if the grid goes
-- off"), api_trends_compare (Live's arrows), calibration_plant() (the plant the
-- phone alerts are bound to). The deployed `forecast` edge function is removed
-- separately with `supabase functions delete forecast`.
-- ============================================================================

do $$
declare j text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - no forecast jobs to remove (expected on the local stack)';
    return;
  end if;
  foreach j in array array['sunsynk-forecast', 'sunsynk-forecast-cal'] loop
    if exists (select 1 from cron.job where jobname = j) then
      perform cron.unschedule(j);
    end if;
  end loop;
end $$;

-- 0058's api_trends_daily without the Expected line.
create or replace function public.api_trends_daily(p_days integer default 30, p_plant bigint default null)
returns jsonb
language sql
stable
set search_path to public, pg_temp
as $fn$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  d as (select least(greatest(coalesce(p_days, 30), 1), 120) as n),
  t as (select public.today_tz((select tz from pz)) as today),
  -- a window of calendar days, not "the last N rows that exist": the chart says last N days
  top as (
    select * from public._plant_day_energy((select id from pl),
                                           ((select today from t) - ((select n from d) - 1))::date,
                                           (select today from t))
  )
  select jsonb_build_object('days', (select n from d),
    'rows', coalesce((select jsonb_agg(
               public._energy_row('day', x.period, x.pv_kwh, x.load_kwh, x.imp_kwh, x.exp_kwh, x.chg_kwh, x.dischg_kwh)
               order by x.period)
        from top x), '[]'::jsonb))
$fn$;

drop function if exists public.api_trends_segments(integer, bigint);
drop function if exists public.q_segment_power(bigint, integer);
drop function if exists public.api_trends_monthly(bigint);

drop function if exists public.api_forecast(bigint);
drop function if exists public.q_forecast_cal_days(bigint, integer);
drop function if exists public.q_forecast_cal_samples(bigint, integer);
drop function if exists public.q_cal_samples(bigint);
drop function if exists public.forecast_k_day();
drop function if exists public.forecast_k();

drop table if exists public.solar_forecast;
drop table if exists public.solar_forecast_cal;

-- ── explicit table rights for the tables added in 0068-0073 ─────────────────
-- Production's default privileges had already granted these tables to anon and
-- authenticated; a fresh database (the local stack) granted nothing, so the
-- SECURITY INVOKER readers (q_day_agg, q_stats, ...) failed there with "permission
-- denied for table agg_5m". Say it once, the same everywhere: signed-in users may
-- read (RLS still limits them to their own plants), anon gets nothing, and only
-- the jobs and triggers write.
revoke all on public.agg_5m, public.readings_5m, public.strings_5m, public.inverter_history_5m,
              public.grid_off, public.config_changes
  from anon, authenticated;
grant select on public.agg_5m, public.readings_5m, public.strings_5m, public.inverter_history_5m,
                public.grid_off, public.config_changes
  to authenticated;
grant all on public.agg_5m, public.readings_5m, public.strings_5m, public.inverter_history_5m,
             public.grid_off, public.config_changes
  to service_role;
