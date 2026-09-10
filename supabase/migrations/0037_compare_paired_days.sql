-- ============================================================================
-- 0037 — Overview trend arrows compare only days present in both periods.
--
-- Before: "this year" summed 1 Jan..today against 1 Jan..same day last year.
-- A plant whose log starts mid-year compared a full current slice against a
-- few days of the previous one and showed a huge rise until the second full
-- year. Same for Month after any gap, and for every new customer's first year.
--
-- Now each day of the current slice is paired with its counterpart in the
-- previous period (yesterday, day-7, same day-of-month last month, same date
-- last year). Only pairs where BOTH days have a plant_energy row count; both
-- sums are over those days. `days` says how many pairs were compared so the
-- UI can say "vs last year, 40 days compared" and hide the arrow when there
-- are too few. Same shape as before plus `days` and `span` (days in the
-- current slice) per key.
--
-- Week/Month/Year pair completed days only (up to yesterday): today's
-- plant_energy row is refreshed daily, so mid-afternoon it still reads near
-- zero and would drag the current side down. Today stays its own single pair
-- and the UI uses the live tile value for its current side.
-- ============================================================================

create or replace function public.api_trends_compare(p_plant bigint default null)
returns jsonb language sql stable set search_path = public, pg_temp
as $$
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
  matched as (
    select p.k, p.cur, p.prev,
           c.pv_kwh as c_pv, c.load_kwh as c_load, c.imp_kwh as c_imp,
           v.pv_kwh as p_pv, v.load_kwh as p_load, v.imp_kwh as p_imp
      from pairs p
      join public.plant_energy c on c.plant_id = (select id from pl) and c.bucket = 'day' and c.period = p.cur
      join public.plant_energy v on v.plant_id = (select id from pl) and v.bucket = 'day' and v.period = p.prev
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
$$;
