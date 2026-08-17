-- ============================================================================
-- Solar forecast — "what will tomorrow actually produce?"
--
-- clear_sky_shape() answers what a PERFECT day could produce. This answers what the
-- next three days will actually bring, which is the only forward-looking number on
-- the dashboard.
--
-- Source: Open-Meteo (open-meteo.com) — keyless, free for non-commercial use, and
-- it returns plane-of-array irradiance directly given tilt/azimuth, so the panel
-- geometry we already model doesn't have to be re-derived from GHI.
--
-- THREE THINGS THAT ARE EASY TO GET WRONG, all verified against the live API:
--
--   1. Azimuth convention is 0 = south, -90 = east, +90 = west. PANEL_AZIMUTH is
--      degrees from NORTH, so it needs converting (340 -> 160). Verified by asking
--      for due-east and due-west panels and checking which one peaks in the
--      morning, rather than trusting the docs — a sign flip here is precisely the
--      silently-skewed curve that 0005_solar_config.sql warns about.
--
--   2. Use the `_instant` variables. Open-Meteo's default radiation values are
--      means over the PRECEDING hour, so the value stamped 15:00 describes 14:30.
--      That fakes a 30-minute afternoon skew — it made a due-north panel look 54%
--      afternoon-biased. With global_tilted_irradiance_instant the shape tracks
--      clear_sky_shape() closely (afternoon skew 1.42 vs our 1.35, same peak hour).
--
--   3. Irradiance is W/m², not watts. It has to be scaled to THIS array, which is
--      what the solar_forecast_cal constants are: numbers fitted against our own
--      logged production rather than assumed from a datasheet. See below.
--
-- CALIBRATION, and why there is no separate bias correction.
--
-- Open-Meteo's archive API serves the same irradiance variables historically, so the
-- Edge Function fits against months of our own readings. Refitting on a rolling recent
-- window means the fit absorbs everything a bias term would have — soiling, seasonal
-- angle, inverter derate, systematic forecast error — so there is no model-plus-fudge
-- -factor to keep in step, just a refit on a schedule.
--
-- Curtailment is the thing that makes this harder than a regression. When the battery
-- is charging at its limit and the house is quiet, the inverter stops harvesting what
-- it cannot place, and pv_w falls away from irradiance for reasons that have nothing to
-- do with the sky. Any fit that ignores this measures household consumption instead of
-- sunshine: across all logged days the conversion ratio medians at 4.52, but across days
-- the battery had headroom it medians at 6.41.
--
-- Curtailment is dodged in two different ways, because the two constants want different
-- things — see the solar_forecast_cal comment below for which and why:
--
--   * the CURVE takes the un-curtailed envelope (SOLAR_CAL_PERCENTILE), exactly as
--     solar_scale_w() does. Sanity check: it puts this array at 9.5 kW peak against the
--     independently-fitted clear-sky model's 8.7 — two unrelated routes within ~6%.
--   * the DAILY TOTAL takes the median of days the battery had headroom, because a
--     forecast should be what you will probably get, not a ceiling you will rarely hit.
--
-- Note the daily figure is still generation the ARRAY could make, not what will
-- necessarily land in the logs: on a day sunnier than the house and battery can absorb,
-- the inverter throttles and logged output comes in under the forecast. That is a
-- consumption outcome, not a forecasting error.
-- ============================================================================

-- Longitude was never needed before — clear_sky_shape() works off the hour angle,
-- for which local time is enough. Fetching weather needs an actual location.
insert into public.app_config (key, value, note) values
  ('LON', 28.0473, 'longitude for the weather forecast (LAT already exists)')
on conflict (key) do update set note = excluded.note;

-- ---------------------------------------------------------------------------
-- The forecast itself: one row per hour, keyed by hour so a later fetch replaces
-- an earlier one for the same hour rather than accumulating revisions.
--
-- Raw weather is stored, NOT modelled watts. Watts are derived at read time from
-- the current k, so refitting the calibration retroactively improves every
-- forecast on file instead of only the ones fetched afterwards.
-- ---------------------------------------------------------------------------
create table if not exists public.solar_forecast (
  ts         bigint primary key,   -- epoch seconds, on the hour, local clock
  gti_wm2    double precision,     -- plane-of-array irradiance, instantaneous
  ghi_wm2    double precision,     -- horizontal, kept for sanity-checking the fit
  cloud_pct  double precision,
  temp_c     double precision,
  fetched_at timestamptz not null default now()
);
create index if not exists solar_forecast_day_idx on public.solar_forecast (public.local_day(ts));

-- ---------------------------------------------------------------------------
-- The fitted scale. Single row, same shape as solar_cal.
--
-- TWO constants, because the dashboard asks irradiance two different questions and a
-- single number cannot answer both honestly.
--
--   k      instantaneous — AC watts per W/m². Fitted on the upper envelope of
--          minute-level samples, so it describes the best conversion this array
--          achieves. Drives the forecast CURVE, and is the like-for-like counterpart
--          of solar_scale_w(), which is fitted the same way on the same envelope.
--
--   k_day  daily — kWh per kWh/m² of daily irradiance. The MEDIAN of un-curtailed
--          logged days, so it describes a typical day rather than the best one.
--          Drives the headline "tomorrow ~= N kWh".
--
-- k_day is NOT k restated, and it does not even take the same statistic. Two rounds of
-- getting this wrong are worth recording:
--
--   1. Using the instantaneous envelope (9.52) across a whole day forecast 63 kWh when
--      the best day ever logged was 50.1 — a real day never holds best-case conversion
--      from first light to last, so the error compounds across the integral.
--   2. Fitting the daily figure but still at the 95th percentile (7.76) was better and
--      still ~18% high: it predicted 47.6 kWh on a day that logged 32.7, and averaged
--      18% over on the ten brightest un-curtailed days. An envelope is a ceiling, and a
--      forecast should be an expectation.
--
-- Hence the median, over days the battery had headroom: 6.41. Including curtailed days
-- would drag it to 4.52, which measures how much the house happened to use.
--
-- The visible consequence is that integrating the drawn curve does not give exactly
-- the headline kWh. That is deliberate and it matches what the chart already does:
-- the dotted potential line is described in chart.jsx as "a visual reference for a
-- clear day, NOT a measurement". The curve is the reference; the total is the number.
create table if not exists public.solar_forecast_cal (
  id          int primary key default 1 check (id = 1),
  k           double precision,   -- AC watts per W/m² (instantaneous, drives the curve)
  k_day       double precision,   -- kWh per kWh/m² (daily, drives the headline total)
  samples     integer,
  day_samples integer,
  window_days integer,
  fit_lo      double precision,   -- 25th/75th percentile of the per-sample ratios,
  fit_hi      double precision,   -- i.e. how tightly the fit holds. Spread = noisy.
  computed_at timestamptz
);
insert into public.solar_forecast_cal (id) values (1) on conflict do nothing;

-- Fallback until the first fit lands: SYSTEM_KWP at 1000 W/m² reference irradiance,
-- derated 0.82 for inverter/thermal losses. Same spirit as solar_scale_w()'s
-- fallback, so a fresh project still draws a sensible line.
create or replace function public.forecast_k()
returns double precision language sql stable as $$
  select coalesce(
    (select k from public.solar_forecast_cal where id = 1),
    public.cfg('SYSTEM_KWP') * 0.82)
$$;

-- Daily counterpart. The fallback assumes ~5.5 usable sun-hours' worth of conversion
-- against a day's irradiance, which is roughly where the measured fit landed.
create or replace function public.forecast_k_day()
returns double precision language sql stable as $$
  select coalesce(
    (select k_day from public.solar_forecast_cal where id = 1),
    public.cfg('SYSTEM_KWP') * 0.62)
$$;

-- ---------------------------------------------------------------------------
-- Calibration samples. Pairs each stored forecast/archive hour with what the
-- array was actually doing at that instant.
--
-- The irradiance value is instantaneous, so the reading must be too — a whole-hour
-- mean of pv_w would smear a fast-moving morning ramp across the hour and flatten
-- the fit. A +/- 5 minute mean is the compromise: still effectively instantaneous,
-- but not hostage to a single noisy minute.
-- ---------------------------------------------------------------------------
create or replace function public.q_forecast_cal_samples(p_days integer default 120)
returns table (ts bigint, gti double precision, pv_w double precision)
language sql stable as $$
  select f.ts, f.gti_wm2, avg(a.pv_w)::double precision
    from public.solar_forecast f
    join public.agg_minute a
      on a.ts between f.ts - 300 and f.ts + 300
   where f.gti_wm2 > 150                                   -- bright enough to be informative
     and f.ts > extract(epoch from now())::bigint - p_days * 86400
     and a.soc < 85                                        -- un-curtailed: panels running free
   group by f.ts, f.gti_wm2
  having count(*) >= 5
$$;

-- ---------------------------------------------------------------------------
-- Daily calibration samples: what the array harvested on a day, against how much
-- irradiance that day offered.
--
-- Only whole days count. A day the logger missed hours of would look like a poor
-- conversion day rather than a poor logging day and would drag the fit down, so
-- days under 1400 logged minutes (of 1440) are dropped — the same instinct as the
-- `hours >= 24` guard the other q_* calibration queries use.
-- ---------------------------------------------------------------------------
create or replace function public.q_forecast_cal_days(p_days integer default 120)
returns table (day date, pv_kwh double precision, gti_kwh double precision, ratio double precision)
language sql stable as $$
  with irr as (
    -- trapezoidal integral of hourly irradiance -> kWh/m² for the day
    select public.local_day(ts) as day,
           sum(case when ts2 is not null and ts2 - ts <= 7200
                    then (gti_wm2 + gti2) / 2.0 * (ts2 - ts) / 3600.0 else 0 end) / 1000.0 as gti_kwh
      from (select ts, gti_wm2,
                   lead(ts)      over (order by ts) as ts2,
                   lead(gti_wm2) over (order by ts) as gti2
              from public.solar_forecast) f
     group by 1
  ),
  logged as (
    select public.local_day(ts) as day,
           sum(pv_w) / 60000.0 as pv_kwh,
           count(*)            as minutes,
           avg(soc)            as avg_soc
      from public.agg_minute group by 1
  )
  select l.day, l.pv_kwh, i.gti_kwh, l.pv_kwh / i.gti_kwh
    from logged l join irr i using (day)
   where l.minutes >= 1400
     and i.gti_kwh > 3                                    -- ignore deep-overcast days
     -- Days spent with a full battery are curtailed days: the inverter stops harvesting
     -- what it cannot place, so they measure consumption, not sunshine. Including them
     -- drags the median from 6.4 to 4.5 and the forecast would under-read every day.
     and l.avg_soc < 85
     and l.day > (now() at time zone 'Africa/Johannesburg')::date - p_days
$$;

-- ---------------------------------------------------------------------------
-- api_forecast() — everything the dashboard needs, in one call.
--
--   days[]  three-day outlook: kWh, peak watts, mean cloud. Today also carries
--           `remainingKwh`, the only figure that answers "is it worth waiting?"
--   points[] TODAY on the same 5-minute grid api_trends_potential() uses, so the
--           chart can draw it with the existing code path.
--
-- Hourly irradiance is interpolated linearly onto that grid. Over one hour of a
-- smooth solar curve the error is negligible, and it beats drawing visible steps.
-- ---------------------------------------------------------------------------
create or replace function public.api_forecast()
returns jsonb language sql stable as $$
  with k as (select public.forecast_k() as k, public.forecast_k_day() as kd),
  today as (select (now() at time zone 'Africa/Johannesburg')::date as d),
  -- hourly rows, each paired with the next so a 5-minute point can sit between them
  h as (
    select f.ts, f.gti_wm2, f.cloud_pct,
           lead(f.ts)      over (order by f.ts) as ts2,
           lead(f.gti_wm2) over (order by f.ts) as gti2
      from public.solar_forecast f
     where public.local_day(f.ts) >= (select d from today)
  ),
  -- per-day rollup. Trapezoidal integration over the hourly samples: each gap
  -- contributes the mean of its endpoints times its length.
  day_rows as (
    select public.local_day(ts) as day,
           sum(case when ts2 is not null and ts2 - ts <= 7200
                    then (gti_wm2 + gti2) / 2.0 * (ts2 - ts) / 3600.0 else 0 end) as gti_hours,
           sum(case when ts2 is not null and ts2 - ts <= 7200
                         and ts >= extract(epoch from now())::bigint
                    then (gti_wm2 + gti2) / 2.0 * (ts2 - ts) / 3600.0 else 0 end) as gti_hours_left,
           max(gti_wm2) as peak_gti,
           avg(cloud_pct) filter (where gti_wm2 > 50) as cloud
      from h group by 1
  ),
  days as (
    -- Totals use k_day against the day's irradiance in kWh/m²; the peak watt figure
    -- uses the instantaneous k, matching the curve it labels.
    select jsonb_agg(jsonb_build_object(
             'date', day::text,
             'kwh',  round((gti_hours / 1000.0 * (select kd from k))::numeric, 1),
             'remainingKwh', case when day = (select d from today)
                             then round((gti_hours_left / 1000.0 * (select kd from k))::numeric, 1) end,
             'peakW', round(peak_gti * (select k from k)),
             'cloud', round(cloud::numeric)) order by day) as j
      from day_rows where day < (select d from today) + 3
  ),
  -- today's curve on the 5-minute grid
  t0 as (select public.day_start_epoch((select d from today)) as t0),
  pts as (
    select jsonb_agg(jsonb_build_object('t', g.t, 'w', round(
             (h.gti_wm2 + (h.gti2 - h.gti_wm2)
               * ((select t0 from t0) + g.t * 60 - h.ts)::double precision
               / nullif(h.ts2 - h.ts, 0)) * (select k from k))) order by g.t) as j
      from generate_series(0, 1435, 5) g(t)
      join h on (select t0 from t0) + g.t * 60 >= h.ts
            and (select t0 from t0) + g.t * 60 <  h.ts2
  )
  select jsonb_build_object(
    'k',         round((select k from k)::numeric, 2),
    'kDay',      round((select kd from k)::numeric, 2),
    'updatedAt', (select max(fetched_at) from public.solar_forecast),
    'calibrated',(select k is not null from public.solar_forecast_cal where id = 1),
    'samples',   (select samples from public.solar_forecast_cal where id = 1),
    'days',      coalesce((select j from days), '[]'::jsonb),
    'points',    coalesce((select j from pts),  '[]'::jsonb))
$$;

-- ---------------------------------------------------------------------------
-- RLS + grants. Same posture as everything else: authenticated reads, and writes
-- only from the Edge Function via service_role.
-- ---------------------------------------------------------------------------
alter table public.solar_forecast     enable row level security;
alter table public.solar_forecast_cal enable row level security;

do $$
declare t text;
begin
  foreach t in array array['solar_forecast', 'solar_forecast_cal'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)', t || '_read', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end $$;

revoke all on function public.api_forecast() from public, anon;
grant execute on function public.api_forecast() to authenticated, service_role;

revoke all on function public.forecast_k() from public, anon;
grant execute on function public.forecast_k() to authenticated, service_role;

revoke all on function public.forecast_k_day() from public, anon;
grant execute on function public.forecast_k_day() to authenticated, service_role;

-- Calibration is an Edge Function concern, like the other q_* primitives that feed
-- a writer. The browser has no reason to enumerate raw samples.
revoke all on function public.q_forecast_cal_samples(integer) from public, anon, authenticated;
grant execute on function public.q_forecast_cal_samples(integer) to service_role;

revoke all on function public.q_forecast_cal_days(integer) from public, anon, authenticated;
grant execute on function public.q_forecast_cal_days(integer) to service_role;

-- ---------------------------------------------------------------------------
-- Schedule. Same guard as 0009/0011 — a no-op wherever pg_cron isn't enabled,
-- which is how it stays harmless on the local stack.
--
-- Four times a day. Open-Meteo's underlying models refresh on roughly that cadence,
-- so polling harder would return the same numbers; the free tier's 10k calls/day
-- makes 4 a rounding error either way. Offset off the hour to stay clear of poll.
-- ---------------------------------------------------------------------------
do $$
declare
  fn_base  text := 'https://pmakzojwhouamawgszrc.functions.supabase.co';
  auth_hdr text := $hdr$jsonb_build_object(
                     'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
                     'Content-Type', 'application/json')$hdr$;
  j text;
  spec record;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not enabled here - skipping forecast schedule (expected locally)';
    return;
  end if;

  foreach j in array array['sunsynk-forecast', 'sunsynk-forecast-cal'] loop
    if exists (select 1 from cron.job where jobname = j) then
      perform cron.unschedule(j);
    end if;
  end loop;

  for spec in
    select * from (values
      -- the forecast itself, four times daily
      ('sunsynk-forecast',     '23 */6 * * *', 'forecast',                60000),
      -- refit k weekly against the archive. Sunday 03:10 UTC, clear of the other jobs.
      ('sunsynk-forecast-cal', '10 3 * * 0',   'forecast?mode=calibrate', 150000)
    ) as t(jobname, sched, fn, timeout_ms)
  loop
    perform cron.schedule(spec.jobname, spec.sched, format(
      'select net.http_post(url := %L, headers := %s, body := %L::jsonb, timeout_milliseconds := %s);',
      fn_base || '/' || spec.fn, auth_hdr, '{}', spec.timeout_ms));
  end loop;

  raise notice 'scheduled sunsynk-forecast, sunsynk-forecast-cal';
end $$;
