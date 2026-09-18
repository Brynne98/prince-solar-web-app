-- A cached day is only usable once it is FINISHED.
--
-- `sync-plant-energy` runs on one daily cron (15 2 * * * = 04:15 SAST, 0009_schedule.sql)
-- and writes the day it runs on as a partial: at 04:15 that is four hours of overnight load
-- and no sun. Nothing overwrites it for another 24 h. `api_trends_daily` computed *today*
-- live from agg_minute (0013) but read the cache for every earlier day, so between local
-- midnight and 04:15 yesterday was served as that stub — a near-zero bar, which reads as a
-- missing bar. Measured on plant 538820: plant_energy 2026-09-18 = pv 0, load 3, synced_at
-- 02:15 UTC on the 18th, while agg_minute held all 1440 minutes of it at pv 20.0, load 32.9.
--
-- `api_energy` was worse: its week and month buckets had no agg_minute branch at all, so they
-- carried the stub for yesterday AND missed today's generation entirely, all day.
-- `api_trends_compare` joins the cache on both sides of every pair, so the arrows drooped in
-- the same window.
--
-- The rule: a cache row counts as finished only when `synced_at` is past the end of that day
-- in the plant's zone. Days without a finished row come from agg_minute. That is the same
-- transition 0013 already made for today, delayed until the vendor row actually exists rather
-- than flipping to a stub, so a day's source changes once, in one direction, towards the
-- gap-immune vendor counter (§3.4). A row whose pv series is null is treated as unfinished
-- too: the sync writes null for a series SunSynk omitted, and a real 0 must not beat a
-- correct integral.
--
-- Rejected: "prefer agg_minute whenever a day has >= 1400 of 1440 minutes". A gappy day plus
-- a stub row falls back to the stub, which under-reports worse than the gaps; and a day's
-- source would flip weeks later when `recover` fills a hole, moving bars after the fact.
--
-- Known and accepted, unchanged from 0013: the cache scales grid by `q_grid_feed_scale`
-- (master-only CT figures up to the whole plant) where agg_minute sums each inverter's own
-- measured watts, so at 04:15 a day steps by that delta — ~1% on pv and load, more on
-- import/export. Today's bar already does this at midnight.

-- One place the rule lives, so the three readers cannot drift apart. In `public` with a
-- leading underscore, as `_energy_row` already is: the api_* readers run as the invoker, so a
-- helper in `private` would need the whole schema opened to `authenticated`. Runs as invoker
-- too, so RLS on plant_energy and agg_minute still applies and the caller's `my_plant()`
-- check is what decides which plant it can see.
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
  -- every day in the window the cache cannot answer for: today, yesterday before the sync,
  -- any day a sync outage skipped, and (harmlessly) days before this plant existed
  gaps as (
    select g::date as period, tz.z as z
      from tz, generate_series(p_from, p_to, interval '1 day') g
     where not exists (select 1 from fin f where f.period = g::date)
  ),
  -- bounds per gap day so agg_minute is hit with one index range per day that needs it,
  -- never a single scan spanning the whole window
  gapr as (
    select period,
           public.day_start_epoch_tz(period, z) as lo,
           public.day_start_epoch_tz((period + 1)::date, z) as hi
      from gaps
  ),
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
     group by r.period
  )
  select * from fin
  union all
  select * from live
$fn$;

comment on function public._plant_day_energy(bigint, date, date) is
  'Day kWh for a plant over [p_from, p_to]: finished plant_energy rows, and agg_minute for any day whose cache row is unfinished, missing or null. See 0058.';

grant execute on function public._plant_day_energy(bigint, date, date) to authenticated, service_role;

-- ---------------------------------------------------------------- readers

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
  ),
  -- expected generation is the single-site forecast: only meaningful for the calibration plant
  expected as (
    select public.local_day_tz(ts, (select tz from pz)) as period,
           sum(case when ts2 is not null and ts2 - ts <= 7200 then (gti_wm2 + gti2) / 2.0 * (ts2 - ts) / 3600.0 else 0 end) / 1000.0 * public.forecast_k_day() as kwh
      from (select ts, gti_wm2, lead(ts) over (order by ts) as ts2, lead(gti_wm2) over (order by ts) as gti2 from public.solar_forecast) f
     where (select id from pl) = public.calibration_plant()
     group by 1
  )
  select jsonb_build_object('days', (select n from d),
    'rows', coalesce((select jsonb_agg(
               public._energy_row('day', x.period, x.pv_kwh, x.load_kwh, x.imp_kwh, x.exp_kwh, x.chg_kwh, x.dischg_kwh)
               || case when e.kwh is not null then jsonb_build_object('expected', round(e.kwh::numeric, 1)) else '{}'::jsonb end
               order by x.period)
        from top x left join expected e on e.period = x.period), '[]'::jsonb))
$fn$;

create or replace function public.api_energy(p_period text default 'week', p_plant bigint default null)
returns jsonb
language sql
stable
set search_path to public, pg_temp
as $fn$
  with pl as (select public.my_plant(p_plant) as id),
  today as (select public.today_tz(public.plant_tz((select id from pl))) as d),
  period as (select case when p_period in ('week','month','year','lifetime') then p_period else 'week' end as p),
  -- week and month are built from day rows, so they follow the finished-row rule and now
  -- carry today as well; year and lifetime stay on the vendor's month buckets
  dayrows as (
    select 'day'::text as bucket, e.period, e.pv_kwh, e.load_kwh, e.imp_kwh, e.exp_kwh, e.chg_kwh, e.dischg_kwh
      from period, today,
           public._plant_day_energy((select id from pl),
             case period.p when 'month' then date_trunc('month', today.d)::date
                            else date_trunc('week', today.d)::date end,
             today.d) e
     where period.p in ('week','month')
  ),
  monthrows as (
    select e.bucket, e.period, e.pv_kwh, e.load_kwh, e.imp_kwh, e.exp_kwh, e.chg_kwh, e.dischg_kwh
      from public.plant_energy e, today, period
     where e.plant_id = (select id from pl)
       and period.p in ('year','lifetime')
       and case period.p
             when 'year' then e.bucket = 'month' and extract(year from e.period) = extract(year from today.d)
             else e.bucket = 'month' end
  ),
  rows as (select * from dayrows union all select * from monthrows)
  select jsonb_build_object('period', (select p from period),
    'rows', coalesce((select jsonb_agg(public._energy_row(r.bucket, r.period, r.pv_kwh, r.load_kwh, r.imp_kwh, r.exp_kwh, r.chg_kwh, r.dischg_kwh) order by r.period) from rows r), '[]'::jsonb))
$fn$;

create or replace function public.api_trends_compare(p_plant bigint default null)
returns jsonb
language sql
stable
set search_path to public, pg_temp
as $fn$
  with pl as (select public.my_plant(p_plant) as id),
  t as (select public.today_tz(public.plant_tz((select id from pl))) as d),
  b as (
    select d,
           date_trunc('week', d)::date  as week_start,
           date_trunc('month', d)::date as month_start,
           date_trunc('year', d)::date  as year_start
      from t
  ),
  -- current-slice days with the previous-period day each is paired to
  pairs as (
    select 'today' as k, b.d as cur, (b.d - 1)::date as prev from b
    union all
    select 'week', g::date, (g - interval '7 days')::date
      from b, generate_series(b.week_start, b.d - 1, interval '1 day') g
    union all
    -- same day number last month; days that do not exist last month (31st vs a
    -- 30-day month) pair with nothing and drop out
    select 'month', g::date,
           case when extract(day from (b.month_start - interval '1 month' + (extract(day from g)::int - 1) * interval '1 day'))::int
                     = extract(day from g)::int
                then (b.month_start - interval '1 month' + (extract(day from g)::int - 1) * interval '1 day')::date end
      from b, generate_series(b.month_start, b.d - 1, interval '1 day') g
    union all
    -- same date last year; 29 Feb pairs with nothing
    select 'year', g::date,
           case when (g - interval '1 year') + interval '1 year' = g then (g - interval '1 year')::date end
      from b, generate_series(b.year_start, b.d - 1, interval '1 day') g
  ),
  -- both sides follow the finished-row rule, or a stub yesterday drags every arrow down
  -- for the same four hours
  span as (
    select min(least(cur, coalesce(prev, cur))) as lo,
           max(greatest(cur, coalesce(prev, cur))) as hi
      from pairs
  ),
  e as (select * from public._plant_day_energy((select id from pl), (select lo from span), (select hi from span))),
  matched as (
    select p.k, p.cur, p.prev,
           c.pv_kwh as c_pv, c.load_kwh as c_load, c.imp_kwh as c_imp,
           v.pv_kwh as p_pv, v.load_kwh as p_load, v.imp_kwh as p_imp
      from pairs p
      join e c on c.period = p.cur
      join e v on v.period = p.prev
  ),
  spans as (select k, count(*) as span from pairs group by k),
  sums as (
    select s.k,
           jsonb_build_object(
             'cur',  jsonb_build_object('pv', coalesce(round(sum(m.c_pv)::numeric, 1), 0), 'load', coalesce(round(sum(m.c_load)::numeric, 1), 0), 'imp', coalesce(round(sum(m.c_imp)::numeric, 1), 0)),
             'prev', jsonb_build_object('pv', coalesce(round(sum(m.p_pv)::numeric, 1), 0), 'load', coalesce(round(sum(m.p_load)::numeric, 1), 0), 'imp', coalesce(round(sum(m.p_imp)::numeric, 1), 0)),
             'days', count(m.cur),
             'span', s.span) as v
      from spans s left join matched m on m.k = s.k
     group by s.k, s.span
  )
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from sums
$fn$;
