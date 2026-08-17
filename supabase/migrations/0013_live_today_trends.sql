-- ============================================================================
-- Make TODAY's bar on the Energy trend live.
--
-- api_trends_daily() read plant_energy exclusively. That table is refreshed by
-- sync-plant-energy on a daily cron (02:15 UTC), so today's row is only ever as
-- fresh as the last overnight run — for most of the day the newest bar on the chart
-- showed a few minutes of generation and then stopped, while the Live tab, reading
-- agg_minute directly, showed the real figure. Two views of the same day disagreeing
-- is worse than a missing bar.
--
-- So today alone is computed live from agg_minute; every earlier day still comes from
-- the cache, unchanged.
--
-- THE CAVEAT, because this mixes two sources into one chart.
--
-- plant_energy comes from SunSynk's plant feed; agg_minute is our own per-minute log
-- summed locally. They are close but not identical — DATA_PIPELINE.md §3.2 records
-- that SunSynk's plant-level scaling is unstable and needs calibration, which is why
-- q_grid_feed_scale() exists. Import/export are the most exposed to this, since
-- SunSynk only counts grid on CT-bearing inverters.
--
-- That trade is deliberate: a today bar that is slightly inconsistent in convention
-- with yesterday's beats one that is flatly wrong all day. It also only affects the
-- newest bar, which is the one a reader is least likely to compare precisely.
--
-- Battery charge/discharge use the storage convention (+ = charging), matching
-- q_day_agg and the rest of the query layer.
-- ============================================================================

create or replace function public.api_trends_daily(p_days integer default 30)
returns jsonb language sql stable as $$
  with d as (select least(greatest(coalesce(p_days, 30), 1), 120) as n),
  t as (select (now() at time zone 'Africa/Johannesburg')::date as today),
  -- today, straight off the minute log
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
    having count(*) > 0                               -- before the first minute lands, no row
  ),
  -- every previous day, from the cache exactly as before
  cached as (
    select e.period, e.pv_kwh, e.load_kwh, e.imp_kwh, e.exp_kwh, e.chg_kwh, e.dischg_kwh
      from public.plant_energy e, d, t
     where e.bucket = 'day' and e.period < t.today
     order by e.period desc limit (select n from d)
  ),
  merged as (
    select * from cached
    union all
    select * from live
  ),
  -- trim to the requested window AFTER merging, so adding today doesn't silently
  -- return one bar more than asked for
  top as (select * from merged order by period desc limit (select n from d))
  select jsonb_build_object('days', (select n from d),
    'rows', coalesce((
      select jsonb_agg(public._energy_row('day', x.period, x.pv_kwh, x.load_kwh,
                                          x.imp_kwh, x.exp_kwh, x.chg_kwh, x.dischg_kwh)
                       order by x.period)
        from top x), '[]'::jsonb))
$$;

-- CREATE OR REPLACE keeps the existing ACL, but be explicit rather than rely on it.
revoke all on function public.api_trends_daily(integer) from public, anon;
grant execute on function public.api_trends_daily(integer) to authenticated, service_role;
