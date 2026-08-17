-- ============================================================================
-- Add `expected` to the daily energy rows — the dotted "Expected" line on the Energy trend.
--
-- Each day's stored hourly irradiance, integrated and scaled by forecast_k_day(), i.e.
-- the same number the Solar Outlook card shows for the days ahead, computed backwards
-- over the days behind. No new storage: solar_forecast already holds hourly irradiance
-- for ~120 days (the weekly calibration backfills that window) and the 6-hourly fetch
-- keeps it current, retained for 400 days.
--
-- For a PAST day the stored irradiance is Open-Meteo's archive/analysis rather than the
-- forecast that was issued at the time. That is deliberate: it is the better record of
-- how much sun actually arrived, which is what the line is for. This is NOT a
-- forecast-accuracy history, and it should not be read as one.
--
-- WHAT THE GAP BETWEEN THE LINES IS, AND IS NOT.
--
-- forecast_k_day() is the MEDIAN of un-curtailed days, so the line is a typical day's
-- conversion of that day's sunshine — not a ceiling. Measured over 62 logged days,
-- actual generation pokes above it on 16 of them (26%). That is expected: half of
-- un-curtailed days sit above a median by construction.
--
-- So the gap is NOT a measure of wasted solar. server.js:1130 records why that feature
-- was removed in June 2026 — when the battery is full the inverter throttles the panels
-- and the un-made energy never reaches a sensor, so any such figure is a soft guess.
-- This is a visual reference in the same spirit as the clear-sky line on the day chart:
-- something to eyeball, with no kWh derived from the difference.
--
-- Making the line sit above generation on every single day would need a constant of
-- ~8.70 (the best conversion ever recorded), which would then run ~23 kWh above a
-- typical day's output and imply a permanent daily loss that isn't real.
-- ============================================================================

create or replace function public.api_trends_daily(p_days integer default 30)
returns jsonb language sql stable as $$
  with d as (select least(greatest(coalesce(p_days, 30), 1), 120) as n),
  t as (select (now() at time zone 'Africa/Johannesburg')::date as today),
  -- today, straight off the minute log (migration 0013)
  live as (
    select (select today from t)                      as period,
           sum(pv_w)   / 60000.0                      as pv_kwh,
           sum(load_w) / 60000.0                      as load_kwh,
           sum(greatest(grid_w, 0))  / 60000.0        as imp_kwh,
           sum(greatest(-grid_w, 0)) / 60000.0        as exp_kwh,
           sum(greatest(batt_w, 0))  / 60000.0        as chg_kwh,
           sum(greatest(-batt_w, 0)) / 60000.0        as dischg_kwh
      from public.agg_minute
     where public.local_day(ts) = (select today from t)
    having count(*) > 0
  ),
  cached as (
    select e.period, e.pv_kwh, e.load_kwh, e.imp_kwh, e.exp_kwh, e.chg_kwh, e.dischg_kwh
      from public.plant_energy e, d, t
     where e.bucket = 'day' and e.period < t.today
     order by e.period desc limit (select n from d)
  ),
  merged as (select * from cached union all select * from live),
  top as (select * from merged order by period desc limit (select n from d)),
  -- trapezoidal integral of each day's hourly irradiance -> kWh/m², then scaled
  expected as (
    select public.local_day(ts) as period,
           sum(case when ts2 is not null and ts2 - ts <= 7200
                    then (gti_wm2 + gti2) / 2.0 * (ts2 - ts) / 3600.0 else 0 end)
             / 1000.0 * public.forecast_k_day() as kwh
      from (select ts, gti_wm2,
                   lead(ts)      over (order by ts) as ts2,
                   lead(gti_wm2) over (order by ts) as gti2
              from public.solar_forecast) f
     group by 1
  )
  select jsonb_build_object('days', (select n from d),
    'rows', coalesce((
      select jsonb_agg(
               public._energy_row('day', x.period, x.pv_kwh, x.load_kwh,
                                  x.imp_kwh, x.exp_kwh, x.chg_kwh, x.dischg_kwh)
               -- `expected` is absent, not zero, on days with no irradiance on file, so
               -- the line breaks rather than diving to the axis
               || case when e.kwh is not null
                       then jsonb_build_object('expected', round(e.kwh::numeric, 1))
                       else '{}'::jsonb end
               order by x.period)
        from top x left join expected e on e.period = x.period), '[]'::jsonb))
$$;

revoke all on function public.api_trends_daily(integer) from public, anon;
grant execute on function public.api_trends_daily(integer) to authenticated, service_role;
