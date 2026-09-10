-- ============================================================================
-- 0039 — put the backfill event at the minutes it recovered, not at midnight.
--
-- 0038 stamped one backfill row per day at local midnight, because it counted
-- recovered minutes with a plain group-by. On screen that read as though
-- something happened at 00:00: the 10 Sep row said "2h 33m recovered" at
-- midnight when the recover run was at 20:17 and the hole it filled was
-- 13:09-15:42.
--
-- The run time is not recoverable from the data — agg_minute has no column
-- saying when a row was written, only the minute it describes. But the run time
-- is not what the row is about. The event is about the block of minutes, so it
-- now sits at the first of them, next to the gap it closed.
--
-- Contiguous runs are also split, so a day that lost two separate windows gets
-- two rows rather than one summed total at midnight.
-- ============================================================================
create or replace function public.api_events(p_days integer default 14,
                                             p_plant bigint default null)
returns jsonb
language sql
stable security definer
set search_path = public, pg_temp
as $$
with pl as (select public.my_plant(p_plant) as id),
z as (select public.plant_tz((select id from pl)) as tz),
win as (
  select public.day_start_epoch_tz(
           public.today_tz((select tz from z))
             - (greatest(1, least(120, coalesce(p_days, 14))) - 1),
           (select tz from z)) as lo
),
m as (
  select a.ts, a.pv_w, a.load_w, a.soc, a.source,
         public.local_day_tz(a.ts, (select tz from z)) as day
    from public.agg_minute a
   where a.plant_id = (select id from pl)
     and a.ts >= (select lo from win)
),
reserve as (
  select coalesce((select battery_reserve_pct from public.plant_config
                    where plant_id = (select id from pl)), 20) as pct
),
holes as (
  select prev as from_ts, ts as to_ts,
         public.local_day_tz(prev, (select tz from z)) as day
    from (select ts, lag(ts) over (order by ts) as prev from m) g
   where prev is not null and ts - prev >= 600
),
-- Gaps and islands: consecutive recovered minutes share (ts/60 - row_number()).
recovered as (
  select ts, (ts / 60) - row_number() over (order by ts) as grp
    from m where source is not null and source <> 'poller'
),
banked as (
  select public.local_day_tz(min(ts), (select tz from z)) as day,
         min(ts) as from_ts, count(*) * 60 as secs
    from recovered group by grp having count(*) >= 10
),
peak as (
  select distinct on (day) day, ts, pv_w
    from m where pv_w > 0 order by day, pv_w desc, ts
),
heavy as (
  select distinct on (day) day, ts, load_w
    from m where load_w > 0 order by day, load_w desc, ts
),
full_batt as (
  select distinct on (day) day, ts, soc
    from m where soc >= 100 order by day, ts
),
low_batt as (
  select distinct on (day) day, ts, soc
    from m where soc <= (select pct from reserve) order by day, ts
),
sun as (
  select day,
         min(ts) filter (where pv_w > 50) as first_ts,
         max(ts) filter (where pv_w > 50) as last_ts
    from m group by day
),
ev as (
  select day, from_ts as ts, 'gap' as kind, 'warn' as severity,
         'No data for ' || public.fmt_dur(to_ts - from_ts) as title,
         'ran to ' || to_char(public.local_ts_tz(to_ts, (select tz from z)), 'HH24:MI') ||
         ' · the poller stored nothing' as detail
    from holes
  union all
  select day, from_ts, 'backfill', 'info',
         public.fmt_dur(secs) || ' recovered from SunSynk''s cloud',
         'read back from the inverters'' own uploads, not logged live'
    from banked
  union all
  select day, ts, 'peak_solar', 'info',
         'Peak solar ' || round(pv_w / 1000.0, 2)::text || ' kW', null
    from peak
  union all
  select day, ts, 'peak_load', 'info',
         'Heaviest load ' || round(load_w / 1000.0, 2)::text || ' kW', null
    from heavy
  union all
  select day, ts, 'batt_full', 'info', 'Battery full', null
    from full_batt
  union all
  select day, ts, 'batt_reserve', 'warn', 'Battery down to reserve',
         'down to ' || soc::text || '%, reserve is ' ||
         round((select pct from reserve))::text || '%'
    from low_batt
  union all
  select day, first_ts, 'first_sun', 'info', 'First sun', null
    from sun where first_ts is not null
  union all
  select day, last_ts, 'last_sun', 'info', 'Last sun', null
    from sun where last_ts is not null
),
by_day as (
  select day,
         jsonb_agg(jsonb_build_object(
           'ts', ts, 'kind', kind, 'severity', severity,
           'title', title, 'detail', detail,
           'at', to_char(public.local_ts_tz(ts, (select tz from z)), 'HH24:MI')
         ) order by ts, kind) as events
    from ev group by day
)
select jsonb_build_object(
  'plantId', (select id from pl),
  'timezone', (select tz from z),
  'days', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'events', events)
                                     order by day desc) from by_day), '[]'::jsonb))
$$;

do $$
begin
  execute 'revoke all on function public.api_events(integer,bigint) from public, anon';
  execute 'grant execute on function public.api_events(integer,bigint) to authenticated, service_role';
end $$;
