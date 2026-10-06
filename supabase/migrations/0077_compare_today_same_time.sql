-- ============================================================================
-- 0077 — Live's Today arrows compare with yesterday up to the same time. (SOLAR-28)
--
-- Before: 'today' paired today's live counters with all of yesterday's finished
-- day, so every arrow leaned low until late evening (Est. saved read 0% at 15:00
-- with the day half done), and the frontend hid the arrows before midday to cover
-- the worst of it.
--
-- Now 'today'.prev is yesterday as the Today tiles would have shown it at the same
-- moment, built the way api_overview builds today's tiles:
--   pv, load  the inverters' own day counters, summed over the poll at or just
--             before (today's latest poll − 24 h); rows with no device_time are the
--             junk zero rows SunSynk returns as it goes quiet and are skipped
--   imp       yesterday's 5-minute grid power integrated up to the same clock slot
--             when the day has more than 5 slots, else the import counters
-- No arrow (days 0) when today has no poll yet, or yesterday has no good poll
-- within 15 minutes before the cut-off (an outage hole would compare a stale
-- counter with a fresh one).
--
-- Week, month and year are 0058's paired finished days, unchanged.
--
-- Security definer like api_overview and api_balance: it now reads readings, and
-- under invoker the RLS qual blocks partition pruning (SOLAR-35). my_plant(p_plant)
-- still raises unless auth.uid() is linked to the plant; EXECUTE grants unchanged.
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
  -- current-slice days with the previous-period day each is paired to
  pairs as (
    select 'week' as k, g::date as cur, (g - interval '7 days')::date as prev
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
  ),
  -- ---- today: yesterday up to the same time ----
  y as (
    select (b.d - 1) as d,
           public.day_start_epoch_tz(b.d - 1, (select tz from tz)) as lo,
           public.day_start_epoch_tz(b.d, (select tz from tz)) as today_lo
      from b
  ),
  -- today's latest poll, the one the tiles show; it must be today's
  latest as (
    select r.ts from public.readings r, y
     where r.plant_id = (select id from pl) and r.ts >= y.today_lo
     order by r.ts desc limit 1
  ),
  cut as (select ts - 86400 as ts from latest),
  ninv as (select count(*) as n from public.readings r, latest where r.plant_id = (select id from pl) and r.ts = latest.ts),
  -- yesterday's last good poll at or before the cut-off, with a good row for as many
  -- inverters as today's poll has (one junk row would halve a two-inverter total)
  ypoll as (
    select r.ts from public.readings r, y, cut
     where r.plant_id = (select id from pl)
       and r.ts >= y.lo and r.ts <= cut.ts
       and r.device_time is not null
     group by r.ts
    having count(*) >= (select n from ninv)
     order by r.ts desc limit 1
  ),
  yctr as (
    select sum(r.pv_today_kwh) as pv, sum(r.load_today_kwh) as load, sum(r.grid_import_today_kwh) as imp
      from public.readings r, ypoll
     where r.plant_id = (select id from pl) and r.ts = ypoll.ts and r.device_time is not null
  ),
  ygrid as (
    select coalesce(sum(case when a.grid_w > 0 then a.grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           count(*) as n
      from public.q_day_agg((select id from pl), (select d from y), null) a
     where a.hm <= to_char(public.local_ts_tz((select ts from cut), (select tz from tz)), 'HH24:MI')
  ),
  today as (
    select jsonb_build_object(
             'cur',  jsonb_build_object('pv', 0, 'load', 0, 'imp', 0),
             'prev', jsonb_build_object(
                       'pv',   coalesce(round(c.pv::numeric, 1), 0),
                       'load', coalesce(round(c.load::numeric, 1), 0),
                       'imp',  coalesce(round((case when g.n > 5 then g.imp else c.imp end)::numeric, 1), 0)),
             'days', case when p.ts is not null and p.ts >= (select ts from cut) - 900 then 1 else 0 end,
             'span', 1) as v
      from yctr c, ygrid g
      left join ypoll p on true
  )
  select coalesce((select jsonb_object_agg(k, v) from sums), '{}'::jsonb)
         || jsonb_build_object('today', coalesce((select v from today),
              jsonb_build_object('cur', jsonb_build_object('pv', 0, 'load', 0, 'imp', 0),
                                 'prev', jsonb_build_object('pv', 0, 'load', 0, 'imp', 0), 'days', 0, 'span', 1)))
$fn$;
