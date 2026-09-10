-- ============================================================================
-- 0038_api_events.sql — the Events tab.
--
-- One read: the notable things that happened, newest day first. Everything is
-- derived from agg_minute on the fly rather than stored in an events table, for
-- two reasons.
--
--   * Dropping a kind that turns out to be noise is deleting a CTE. No table is
--     left holding rows nobody reads, and no backfill is needed to add a kind
--     later — it applies to all of history the moment it is written.
--   * Gaps heal. `recover` backfills a hole hours after it opens, and a derived
--     gap event simply stops being returned. private.gaps cannot be used for
--     this: it is append-only and nothing ever clears it, so a row from a hole
--     that was filled weeks ago would still claim the data is missing.
--
-- Deliberately NOT included: grid outages. FEATURES.md §3 is still blocked —
-- no dead-grid reading has been observed, `grid_burst` has caught nothing since
-- the trap was armed on 5 Sep, and grid_volt_v sits on the live side of the
-- relay. An "off-grid 5 h" row here would be a guess dressed up as history.
--
-- Battery temperature and per-string current live in readings/strings, not
-- agg_minute, so hot-battery and dead-string events are not here yet. They need
-- a second scan over a partitioned table; worth it only once these kinds prove
-- they get read.
-- ============================================================================

-- "2h 33m", "45m". Durations in this app are always spoken, never decimal hours.
create or replace function public.fmt_dur(p_secs bigint)
returns text
language sql immutable parallel safe
as $$
  select case
    when p_secs is null    then null
    when p_secs < 3600     then (p_secs / 60)::text || 'm'
    when p_secs % 3600 = 0 then (p_secs / 3600)::text || 'h'
    else (p_secs / 3600)::text || 'h ' || ((p_secs % 3600) / 60)::text || 'm'
  end
$$;

-- A hole of at least 10 minutes is an event. The poller writes every minute, so
-- a one- or two-minute miss is ordinary jitter and would bury the real ones.
-- PV over 50 W is "the sun is up" — above inverter self-noise at dawn.
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

-- Holes. Measured against what is actually stored, so a backfilled hole stops
-- being reported without anything having to delete a row.
holes as (
  select prev as from_ts, ts as to_ts,
         public.local_day_tz(prev, (select tz from z)) as day
    from (select ts, lag(ts) over (order by ts) as prev from m) g
   where prev is not null and ts - prev >= 600
),
-- Minutes that came from SunSynk's cloud rather than our own poller. This one
-- stays true forever: it is provenance, not a fault.
banked as (
  select day, count(*) * 60 as secs
    from m where source is not null and source <> 'poller'
   group by day having count(*) >= 10
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
  select day, public.day_start_epoch_tz(day, (select tz from z)), 'backfill', 'info',
         public.fmt_dur(secs) || ' recovered from SunSynk''s cloud',
         'Those minutes were read back from the inverters'' own uploads, not logged live'
    from banked
  union all
  select day, ts, 'peak_solar', 'info',
         'Peak solar ' || round(pv_w / 1000.0, 2)::text || ' kW',
         null
    from peak
  union all
  select day, ts, 'peak_load', 'info',
         'Heaviest load ' || round(load_w / 1000.0, 2)::text || ' kW',
         null
    from heavy
  union all
  select day, ts, 'batt_full', 'info', 'Battery full', null
    from full_batt
  union all
  select day, ts, 'batt_reserve', 'warn',
         'Battery down to reserve',
         'down to ' || soc::text || '%, reserve is ' || round((select pct from reserve))::text || '%'
    from low_batt
  union all
  select day, first_ts, 'first_sun', 'info', 'First sun', null
    from sun where first_ts is not null
  union all
  select day, last_ts, 'last_sun', 'info', 'Last sun', null
    from sun where last_ts is not null
),

-- Days newest first; inside a day, in the order they happened, so a day reads
-- forwards like a journal entry rather than backwards like a changelog.
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
declare f text;
begin
  foreach f in array array['fmt_dur(bigint)', 'api_events(integer,bigint)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
