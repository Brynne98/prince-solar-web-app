-- ============================================================================
-- The five endpoints that need SunSynk's plant-level history.
--
-- They read public.plant_energy, which sync-plant-energy refreshes daily. Nothing
-- here calls SunSynk, so the browser still has no path to the API or a credential.
--
-- Row shapes match the Express versions exactly (rowsFromEnergy in server.js),
-- including the derived label fields the charts use for axes.
-- ============================================================================

-- gridFeedScale() — db.js:542. inverters / CT-bearing inverters, used by
-- sync-plant-energy to scale the master-only grid figures up to the full plant.
create or replace function public.q_grid_feed_scale()
returns double precision language sql stable as $$
  with n as (
    select count(distinct sn) as inv,
           count(distinct sn) filter (where grid_import_total_kwh > 0) as ct
      from public.readings
  )
  select case when inv > 0 and ct > 0 then inv::double precision / ct else 1 end from n
$$;

-- Shared row shaping: one cached plant_energy row -> the JSON the charts expect.
-- Scalar params rather than a composite type, so CTE records can be passed straight in.
create or replace function public._energy_row(
  p_bucket text, p_period date,
  p_pv double precision, p_load double precision, p_imp double precision,
  p_exp double precision, p_chg double precision, p_dischg double precision)
returns jsonb language sql immutable parallel safe as $$
  select jsonb_build_object(
    'pv', p_pv, 'load', p_load, 'imp', p_imp, 'exp', p_exp,
    'chg', p_chg, 'dischg', p_dischg,
    -- self-sufficiency: share of load not met by imported grid energy
    'selfSuff', case when coalesce(p_load, 0) > 0
                     then greatest(0, least(100, round(((p_load - coalesce(p_imp, 0)) / p_load) * 100)))
                     else 0 end)
  || case when p_bucket = 'day' then
       jsonb_build_object(
         'time', to_char(p_period, 'YYYY-MM-DD'),
         'date', to_char(p_period, 'YYYY-MM-DD'),
         'day', extract(day from p_period)::int,
         'dow', extract(dow from p_period)::int,
         'label', to_char(p_period, 'Dy'),
         'monthLabel', to_char(p_period, 'Mon'))
     else
       -- SunSynk's year endpoint returns zero-padded month numbers ("05"), and the
       -- charts key off this string, so pad rather than emitting "5"
       jsonb_build_object(
         'time', to_char(p_period, 'MM'),
         'date', to_char(p_period, 'MM'),
         'day', to_char(p_period, 'Mon'),
         'label', to_char(p_period, 'Mon'),
         'monthLabel', to_char(p_period, 'Mon'))
     end
$$;

-- convenience wrapper so callers read cleanly
create or replace function public._erow(r public.plant_energy)
returns jsonb language sql immutable parallel safe as $$
  select public._energy_row(r.bucket, r.period, r.pv_kwh, r.load_kwh, r.imp_kwh,
                            r.exp_kwh, r.chg_kwh, r.dischg_kwh)
$$;

-- ---------------------------------------------------------------------------
-- GET /api/history/earliest — roughly the commission date: the first cached day
-- with real production. Bounds the day picker.
-- ---------------------------------------------------------------------------
-- Express looks for the first day with ANY non-zero series, not just PV — a
-- commissioning day can show load or import before it generates anything.
create or replace function public.api_history_earliest()
returns jsonb language sql stable as $$
  select jsonb_build_object('earliest', (
    select to_char(min(period), 'YYYY-MM-DD') from public.plant_energy
     where bucket = 'day'
       and (coalesce(pv_kwh,0) > 0 or coalesce(load_kwh,0) > 0
            or coalesce(imp_kwh,0) > 0 or coalesce(exp_kwh,0) > 0
            or coalesce(chg_kwh,0) > 0 or coalesce(dischg_kwh,0) > 0)))
$$;

-- ---------------------------------------------------------------------------
-- GET /api/energy?period=  (week | month | year | lifetime)
--   week     current calendar week, Monday-start, through today
--   month    current calendar month to date
--   year     this year's months
--   lifetime every month on record
-- ---------------------------------------------------------------------------
create or replace function public.api_energy(p_period text default 'week')
returns jsonb language sql stable as $$
  with today as (select (now() at time zone 'Africa/Johannesburg')::date as d),
  period as (select case when p_period in ('week','month','year','lifetime') then p_period else 'week' end as p),
  rows as (
    select e.* from public.plant_energy e, today, period
     where case period.p
             when 'week'  then e.bucket = 'day'
                            and e.period >= date_trunc('week', today.d)::date
                            and e.period <= today.d
             when 'month' then e.bucket = 'day'
                            and e.period >= date_trunc('month', today.d)::date
                            and e.period <= today.d
             when 'year'  then e.bucket = 'month'
                            and extract(year from e.period) = extract(year from today.d)
             else              e.bucket = 'month'
           end
  )
  select jsonb_build_object(
    'period', (select p from period),
    'rows', coalesce((select jsonb_agg(public._energy_row(r.bucket, r.period, r.pv_kwh, r.load_kwh, r.imp_kwh, r.exp_kwh, r.chg_kwh, r.dischg_kwh) order by r.period) from rows r), '[]'::jsonb))
$$;

-- GET /api/trends/daily?days=  — the last N cached days
create or replace function public.api_trends_daily(p_days integer default 30)
returns jsonb language sql stable as $$
  with d as (select least(greatest(coalesce(p_days, 30), 1), 120) as n),
  rows as (
    select * from public.plant_energy, d
     where bucket = 'day' order by period desc limit (select n from d)
  )
  select jsonb_build_object('days', (select n from d),
    'rows', coalesce((select jsonb_agg(public._energy_row(r.bucket, r.period, r.pv_kwh, r.load_kwh, r.imp_kwh, r.exp_kwh, r.chg_kwh, r.dischg_kwh) order by r.period) from rows r), '[]'::jsonb))
$$;

-- ---------------------------------------------------------------------------
-- GET /api/trends/monthly — every month on record, tagged with year + month so the
-- frontend can also roll them into seasons.
-- ---------------------------------------------------------------------------
create or replace function public.api_trends_monthly()
returns jsonb language sql stable as $$
  select jsonb_build_object('rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'ym', to_char(period, 'YYYY-MM'),
             'year', extract(year from period)::int,
             'month', extract(month from period)::int,
             'label', to_char(period, 'Mon'),
             'pv', pv_kwh, 'load', load_kwh, 'imp', imp_kwh, 'exp', exp_kwh)
           order by period)
      from public.plant_energy where bucket = 'month'), '[]'::jsonb))
$$;

-- ---------------------------------------------------------------------------
-- GET /api/trends/compare — period-over-period totals for the Overview arrows.
--
-- Each current period-to-date is compared against the SAME elapsed slice of the
-- previous period (month days 1..today vs last month days 1..today), so the
-- percentage is fair rather than partial-vs-full.
-- ---------------------------------------------------------------------------
create or replace function public.api_trends_compare()
returns jsonb language sql stable as $$
  with t as (select (now() at time zone 'Africa/Johannesburg')::date as d),
  b as (
    select d,
           d - 1                                              as yesterday,
           date_trunc('week', d)::date                        as week_start,
           (date_trunc('week', d) - interval '7 days')::date  as prev_week_start,
           d - 7                                              as prev_week_end,
           date_trunc('month', d)::date                       as month_start,
           (date_trunc('month', d) - interval '1 month')::date as last_month_start,
           ((date_trunc('month', d) - interval '1 month') + (extract(day from d)::int - 1) * interval '1 day')::date as last_month_same_day,
           date_trunc('year', d)::date                        as year_start,
           (date_trunc('year', d) - interval '1 year')::date  as last_year_start,
           ((date_trunc('year', d) - interval '1 year') + (d - date_trunc('year', d)::date) * interval '1 day')::date as last_year_same_day
      from t
  ),
  -- day-grain totals; year uses the same grain so both sides of the comparison are
  -- measured identically rather than mixing monthly and daily buckets
  agg as (
    select 'today'      as k, 'cur'  as side, b.d as lo, b.d as hi from b
    union all select 'today', 'prev', b.yesterday, b.yesterday from b
    union all select 'week',  'cur',  b.week_start, b.d from b
    union all select 'week',  'prev', b.prev_week_start, b.prev_week_end from b
    union all select 'month', 'cur',  b.month_start, b.d from b
    union all select 'month', 'prev', b.last_month_start, b.last_month_same_day from b
    union all select 'year',  'cur',  b.year_start, b.d from b
    union all select 'year',  'prev', b.last_year_start, b.last_year_same_day from b
  ),
  sums as (
    select a.k, a.side,
           jsonb_build_object(
             'pv',   coalesce(round(sum(e.pv_kwh)::numeric, 1), 0),
             'load', coalesce(round(sum(e.load_kwh)::numeric, 1), 0),
             'imp',  coalesce(round(sum(e.imp_kwh)::numeric, 1), 0)) as v
      from agg a
      left join public.plant_energy e
        on e.bucket = 'day' and e.period between a.lo and a.hi
     group by a.k, a.side
  )
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from (
    select k, jsonb_object_agg(side, v) as v from sums group by k) x
$$;

-- ---------------------------------------------------------------------------
-- Grants. Same rule as the rest of the api_* surface: authenticated only.
-- q_grid_feed_scale is an internal primitive for sync-plant-energy.
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'api_history_earliest()', 'api_energy(text)', 'api_trends_daily(integer)',
    'api_trends_monthly()', 'api_trends_compare()', '_energy_row(text,date,double precision,double precision,double precision,double precision,double precision,double precision)', '_erow(public.plant_energy)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
  execute 'revoke all on function public.q_grid_feed_scale() from public, anon, authenticated';
  execute 'grant execute on function public.q_grid_feed_scale() to service_role';
end $$;
