-- ============================================================================
-- 0051 — the dotted line on the day chart becomes "best recent output": what this
-- plant itself made, per 5-minute slot, on its better days in the 30 days before the
-- date shown, from readings where the panels were not being held back.
--
-- It replaces the clear-sky roof model (clear_sky_shape × solar_cal), which drew one
-- plant only, from one global roof, and cannot describe panels on several roof faces.
-- Nothing about the roof is asked or assumed. Grid is signed + import (the poller
-- normalises it). Limit: a plant with no battery whose export is capped is held back
-- with no charge to show it, and those minutes still count.
--
-- The panels are held back when the battery cannot take more: when it is nearly full,
-- and when it is already charging at its limit (export is capped on these plants, so
-- surplus has nowhere else to go). A reading counts only when
--   soc < 95 (or no battery reported)  and  charge < 90% of the plant's charge ceiling,
-- where charge = pv + grid − load (grid positive = import), and the ceiling is the 99th
-- percentile of that over the window. Fetched plant-feed rows (source 'plantfeed') are
-- left out; their scaling is not trusted (DATA_PIPELINE §3.2).
--
-- Per slot: the mean of each day's qualifying minutes, then the 90th percentile across
-- days, shown only when at least 5 days qualified. The plant gets a line once it has 21
-- days of readings in the window and 85% of the 09:00–15:00 slots have a value ('waiting'
-- says which is missing: 'days', or 'room' when the battery is too often full). Tuned
-- on both production plants (14 Sep 2026): a 14-day window sat 14% of peak away from the
-- 30-day curve on one of them, 21 days 2%; with 5 days per slot 100% and 91% of midday
-- slots filled.
--
-- Computed when the chart asks (one plant, 30 days of minutes), so a past date gets the
-- window before that date. Nothing to store, nothing to schedule.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Retire the roof model (and the unshipped per-plant roof work, where present)
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from cron.job where jobname = 'sunsynk-solar-cal') then
    perform cron.unschedule('sunsynk-solar-cal');
  end if;
exception when others then
  raise notice 'solar-cal unschedule skipped: %', sqlerrm;
end $$;

drop function if exists public.q_recompute_solar_scales();
drop function if exists public.q_recompute_solar_scale(bigint);
drop function if exists public.solar_scale_w(bigint);
drop function if exists public.solar_scale_w();
drop function if exists public.forecast_geometry();
drop function if exists public.plant_panels(bigint);
drop function if exists public.clear_sky_shape(bigint, double precision, double precision, double precision, text);
drop function if exists public.clear_sky_shape(bigint);
drop table if exists public.plant_solar_cal;
drop table if exists public.solar_cal;

-- ---------------------------------------------------------------------------
-- 2. The line
-- ---------------------------------------------------------------------------
drop function if exists public.api_trends_potential(date, bigint);
create or replace function public.api_trends_potential(p_date date default null, p_plant bigint default null)
returns jsonb
language sql stable
set search_path = public, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  z as (select public.plant_tz((select id from pl)) as tz),
  d as (select coalesce(p_date, public.today_tz((select tz from z))) as day),
  win as (
    select public.day_start_epoch_tz((select day from d) - 30, (select tz from z)) as lo,
           public.day_start_epoch_tz((select day from d), (select tz from z)) as hi
  ),
  m as (
    select a.ts, a.pv_w, a.soc,
           a.pv_w + coalesce(a.grid_w, 0) - coalesce(a.load_w, 0) as charge_w,
           public.local_ts_tz(a.ts, (select tz from z)) as lt
      from public.agg_minute a, win
     where a.plant_id = (select id from pl)
       and a.ts >= win.lo and a.ts < win.hi
       and a.pv_w is not null
       and a.load_w is not null        -- without load, charge = pv would read as held back
       and coalesce(a.source, 'poller') <> 'plantfeed'
  ),
  ceil as (select percentile_cont(0.99) within group (order by charge_w) as w from m where charge_w > 0),
  per_day as (
    select m.lt::date as day,
           floor((extract(hour from m.lt) * 60 + extract(minute from m.lt)) / 5)::int as slot,   -- floor: ::int would round 13:03 into 13:05
           avg(m.pv_w) as w
      from m, ceil
     where (m.soc is null or m.soc < 95)
       and (ceil.w is null or m.charge_w < 0.9 * ceil.w)
     group by 1, 2
  ),
  slots as (
    select slot, count(*) as days, percentile_cont(0.9) within group (order by w) as w
      from per_day group by slot
  ),
  cover as (
    select count(*) filter (where days >= 5)::numeric / 72 as midday
      from slots where slot >= 108 and slot < 180          -- 09:00–15:00
  ),
  seen as (select count(distinct lt::date) as days from m)
  select jsonb_build_object(
    'date', (select day from d)::text,
    'days', (select days from seen),
    'needDays', 21,
    'available', (select days from seen) >= 21 and coalesce((select midday from cover), 0) >= 0.85,
    'waiting', case when (select days from seen) < 21 then 'days'
                    when coalesce((select midday from cover), 0) < 0.85 then 'room' end,
    'points', coalesce((
      select jsonb_agg(jsonb_build_object('t', g.s * 5,
               'w', case when s.days >= 5 then round(s.w) end) order by g.s)
        from generate_series(0, 287) g(s) left join slots s on s.slot = g.s), '[]'::jsonb))
$$;
revoke all on function public.api_trends_potential(date, bigint) from public, anon;
grant execute on function public.api_trends_potential(date, bigint) to authenticated, service_role;
