-- 0058 made _plant_day_energy fill every day in its window that had no finished cache row.
-- api_trends_compare asks for a span reaching back to the start of last year, and every day
-- before this plant existed has no cache row at all, so the function probed agg_minute once
-- per pre-history day: ~150 probes, 2.3 s on a small local database, and over the
-- `authenticated` role's statement_timeout on the hosted one. The compare RPC returned
-- 57014 and the Live trend arrows and the Solar tab's "on last week" badges vanished
-- (fetchCompare swallows the error), which is how it hid.
--
-- The bug 0058 fixed only ever concerns the newest day or two, so the agg_minute fill is now
-- bounded to the last 14 days of the requested window: enough slack to cover a two-week sync
-- outage, short enough that the probe count is a constant. The finished-row test still applies
-- to the whole window, so an older stub is never served as if it were complete — such a day is
-- absent instead, which is the gap the log is supposed to show rather than a wrong number.
create or replace function public._plant_day_energy(p_plant bigint, p_from date, p_to date)
returns table (period date, pv_kwh double precision, load_kwh double precision,
               imp_kwh double precision, exp_kwh double precision,
               chg_kwh double precision, dischg_kwh double precision)
language sql
stable
set search_path to public, pg_temp
as $fn$
  with tz as (select public.plant_tz(p_plant) as z),
  fin as (
    select e.period, e.pv_kwh, e.load_kwh, e.imp_kwh, e.exp_kwh, e.chg_kwh, e.dischg_kwh
      from public.plant_energy e, tz
     where e.plant_id = p_plant and e.bucket = 'day'
       and e.period between p_from and p_to
       and e.pv_kwh is not null
       and e.synced_at >= to_timestamp(public.day_start_epoch_tz((e.period + 1)::date, tz.z))
  ),
  -- days the cache cannot answer for, within a fortnight of the window's end: today,
  -- yesterday before the sync, and any day a sync outage skipped. Older days with no
  -- finished row stay absent, as they were before 0058.
  gaps as (
    select g::date as period, tz.z as z
      from tz, generate_series(greatest(p_from, (p_to - 14)::date), p_to, interval '1 day') g
     where not exists (select 1 from fin f where f.period = g::date)
  ),
  gapr as (
    select period,
           public.day_start_epoch_tz(period, z) as lo,
           public.day_start_epoch_tz((period + 1)::date, z) as hi
      from gaps
  ),
  -- one index range per gap day, and an outer bound as well so the planner sees a single
  -- narrow window over agg_minute rather than an unbounded scan per day
  live as (
    select r.period,
           sum(m.pv_w) / 60000.0 as pv_kwh, sum(m.load_w) / 60000.0 as load_kwh,
           sum(greatest(m.grid_w, 0)) / 60000.0 as imp_kwh,
           sum(greatest(-m.grid_w, 0)) / 60000.0 as exp_kwh,
           sum(greatest(m.batt_w, 0)) / 60000.0 as chg_kwh,
           sum(greatest(-m.batt_w, 0)) / 60000.0 as dischg_kwh
      from gapr r
      join public.agg_minute m
        on m.plant_id = p_plant and m.ts >= r.lo and m.ts < r.hi
     where m.ts >= (select min(lo) from gapr) and m.ts < (select max(hi) from gapr)
     group by r.period
  )
  select * from fin
  union all
  select * from live
$fn$;
