-- ============================================================================
-- 0079 — the matching moment is the same clock time, not the same time since
-- midnight. (SOLAR-69)
--
-- 0078 read each matching day at its midnight plus the seconds today has run.
-- On a daylight-saving change that is an hour off: on the 25-hour day 13:00 is
-- 14 hours in, so yesterday was read at 14:00, and the day after read the change
-- day at 12:00 (SOLAR-68 test report). Now today's latest poll is turned into a
-- local clock time and each matching day is read at that clock time in the
-- plant's zone. Plants without daylight saving (all of South Africa) get the
-- same moment as before. Everything else is 0078.
-- ============================================================================

create or replace function public.api_trends_compare(p_plant bigint default null)
returns jsonb
language sql
stable
security definer
set search_path to public, pg_temp
as $fn$
  with pl as (select public.my_plant(p_plant) as id),
  tz as (select public.plant_tz((select id from pl)) as tz),
  t as (select public.today_tz((select tz from tz)) as d),
  b as (
    select d,
           date_trunc('week', d)::date  as week_start,
           date_trunc('month', d)::date as month_start,
           date_trunc('year', d)::date  as year_start
      from t
  ),
  -- same day number last month, null when last month has no such day
  lastm as (
    select g::date as cur,
           case when extract(day from (date_trunc('month', g) - interval '1 month' + (extract(day from g)::int - 1) * interval '1 day'))::int
                     = extract(day from g)::int
                then (date_trunc('month', g) - interval '1 month' + (extract(day from g)::int - 1) * interval '1 day')::date end as prev
      from b, generate_series(b.month_start, b.d, interval '1 day') g
  ),
  -- finished current-slice days with the previous-period day each is paired to
  pairs as (
    select 'week' as k, g::date as cur, (g - interval '7 days')::date as prev
      from b, generate_series(b.week_start, b.d - 1, interval '1 day') g
    union all
    select 'month', cur, prev from lastm, b where cur < b.d
    union all
    -- same date last year; 29 Feb pairs with nothing
    select 'year', g::date,
           case when (g - interval '1 year') + interval '1 year' = g then (g - interval '1 year')::date end
      from b, generate_series(b.year_start, b.d - 1, interval '1 day') g
  ),
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
  -- every period gets a row, even on its first day when no finished day pairs yet
  spans as (
    select ks.k, count(p.cur) as span
      from (values ('week'), ('month'), ('year')) ks(k) left join pairs p on p.k = ks.k
     group by ks.k
  ),
  sums as (
    select s.k,
           jsonb_build_object(
             'cur',  jsonb_build_object('pv', coalesce(round(sum(m.c_pv)::numeric, 1), 0), 'load', coalesce(round(sum(m.c_load)::numeric, 1), 0), 'imp', coalesce(round(sum(m.c_imp)::numeric, 1), 0)),
             'prev', jsonb_build_object('pv', coalesce(round(sum(m.p_pv)::numeric, 1), 0), 'load', coalesce(round(sum(m.p_load)::numeric, 1), 0), 'imp', coalesce(round(sum(m.p_imp)::numeric, 1), 0)),
             'days', count(m.cur),
             'span', s.span) as v
      from spans s left join matched m on m.k = s.k
     group by s.k, s.span
  ),
  -- ---- today so far, and the day it pairs with up to the same time ----
  tlo as (select public.day_start_epoch_tz(b.d, (select tz from tz)) as lo from b),
  -- today's latest poll, the one the tiles show; it must be today's
  latest as (
    select r.ts from public.readings r, tlo
     where r.plant_id = (select id from pl) and r.ts >= tlo.lo
     order by r.ts desc limit 1
  ),
  -- today's latest poll as a local clock time; each matching day is read at that clock time
  el as (select (to_timestamp(latest.ts) at time zone (select tz from tz))::time as t from latest),
  tpairs as (
    select 'today' as k, (b.d - 1) as prev from b
    union all select 'week', (b.d - 7) from b
    union all select 'month', (select prev from lastm, b where lastm.cur = b.d)
    union all select 'year', case when (b.d - interval '1 year') + interval '1 year' = b.d then (b.d - interval '1 year')::date end from b
  ),
  tc as (
    select p.k, p.prev, x.lo, extract(epoch from ((p.prev + el.t) at time zone (select tz from tz)))::bigint as cut
      from tpairs p, el,
           lateral (select public.day_start_epoch_tz(p.prev, (select tz from tz)) as lo) x
     where p.prev is not null
  ),
  -- each inverter in today's poll: its last good reading on the matching day at or
  -- before the moment, from readings, else the 5-minute history (counters as at the
  -- bucket's end). One index probe per inverter per pair.
  inv as (select r.sn from public.readings r, latest where r.plant_id = (select id from pl) and r.ts = latest.ts),
  per as (
    select tc.k, i.sn,
           coalesce(x.pv, y.pv) as pv, coalesce(x.load, y.load) as load, coalesce(x.imp, y.imp) as imp,
           (x.ts is not null or y.ts is not null) as found
      from tc cross join inv i
      left join lateral (
        select r.ts, r.pv_today_kwh as pv, r.load_today_kwh as load, r.grid_import_today_kwh as imp
          from public.readings r
         where r.sn = i.sn and r.plant_id = (select id from pl)
           and r.ts >= tc.lo and r.ts <= tc.cut and r.device_time is not null
         order by r.ts desc limit 1) x on true
      left join lateral (
        select f.ts, f.pv_today_kwh as pv, f.load_today_kwh as load, f.grid_import_today_kwh as imp
          from public.readings_5m f
         where x.ts is null
           and f.plant_id = (select id from pl) and f.sn = i.sn
           and f.ts >= tc.lo and f.ts <= tc.cut - 300 and f.pv_today_kwh is not null
         order by f.ts desc limit 1) y on true
  ),
  ctr as (
    select k, sum(pv) as pv, sum(load) as load, sum(imp) as imp
      from per group by k
    having bool_and(found)
  ),
  ig as (
    select tc.k,
           coalesce(sum(case when a.grid_w > 0 then a.grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           count(a.hm) as n
      from tc left join lateral (
        select q.hm, q.grid_w from public.q_day_agg((select id from pl), tc.prev, null) q
         where q.hm <= to_char(public.local_ts_tz(tc.cut, (select tz from tz)), 'HH24:MI')) a on true
     group by tc.k
  ),
  nowv as (
    select c.k, jsonb_build_object(
             'pv',   coalesce(round(c.pv::numeric, 1), 0),
             'load', coalesce(round(c.load::numeric, 1), 0),
             'imp',  coalesce(round((case when g.n > 5 then g.imp else c.imp end)::numeric, 1), 0)) as v
      from ctr c join ig g on g.k = c.k
  )
  select coalesce((select jsonb_object_agg(s.k, s.v || jsonb_build_object('now', (select v from nowv where nowv.k = s.k))) from sums s), '{}'::jsonb)
         || jsonb_build_object('today', jsonb_build_object(
              'cur',  jsonb_build_object('pv', 0, 'load', 0, 'imp', 0),
              'prev', coalesce((select v from nowv where k = 'today'), jsonb_build_object('pv', 0, 'load', 0, 'imp', 0)),
              'days', case when exists (select 1 from nowv where k = 'today') then 1 else 0 end,
              'span', 1))
$fn$;
