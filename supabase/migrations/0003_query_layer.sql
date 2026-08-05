-- ============================================================================
-- The db.js query layer, ported to Postgres.
--
-- These are the internal query primitives (the equivalent of db.js's exports).
-- The endpoint-shaped RPCs the frontend calls are built on top of these in a later
-- migration, exactly as server.js composes db.js.
--
-- Translation notes, SQLite -> Postgres:
--   strftime('%Y-%m-%d', ts,'unixepoch','localtime')  ->  local_day(ts)
--   CAST(strftime('%H', ...) AS INTEGER)              ->  local_hour(ts)
--   MIN(a,b)   (SQLite 2-arg scalar)                  ->  least(a,b)
--   ROUND(AVG(x))                                     ->  round(avg(x)::numeric)
--   INSERT OR IGNORE                                  ->  on conflict do nothing
-- ============================================================================

-- Local wall-clock timestamp for an epoch second. local_day/local_hour (0001) are
-- the indexed forms; these cover the minute-level bucketing dayAgg needs.
create or replace function public.local_ts(ts bigint)
returns timestamp language sql immutable parallel safe
as $$ select to_timestamp(ts) at time zone 'Africa/Johannesburg' $$;

create or replace function public.local_minute(ts bigint)
returns integer language sql immutable parallel safe
as $$ select extract(minute from (to_timestamp(ts) at time zone 'Africa/Johannesburg'))::int $$;

-- Epoch second of local midnight for a local date. The JS equivalent is
-- `new Date(y, mo-1, d).getTime()/1000`, which is local-midnight on the host.
create or replace function public.day_start_epoch(d date)
returns bigint language sql immutable parallel safe
as $$ select extract(epoch from (d::timestamp at time zone 'Africa/Johannesburg'))::bigint $$;

-- ---------------------------------------------------------------------------
-- getStats() — db.js:146. The `raw` table isn't ported, so its counters report 0.
-- ---------------------------------------------------------------------------
create or replace function public.q_stats()
returns table (
  agg_rows bigint, days bigint, first_ts bigint, last_ts bigint, per_inverter_rows bigint)
language sql stable as $$
  select
    (select count(*) from public.agg_minute),
    (select count(distinct public.local_day(ts)) from public.agg_minute),
    (select min(ts) from public.agg_minute),
    (select max(ts) from public.agg_minute),
    (select count(*) from public.readings)
$$;

-- ---------------------------------------------------------------------------
-- byHour() — db.js:178. Average profile by hour-of-day over the last `days`.
-- Only days with all 24 hours present are averaged, so partial/outage days and
-- today (still in progress) don't skew the means.
-- ---------------------------------------------------------------------------
create or replace function public.q_by_hour(p_days integer default 14)
returns table (
  hour integer, pv_w numeric, load_w numeric, baseline_load_w numeric,
  grid_w numeric, soc numeric, samples bigint, surplus_w numeric, spare_w numeric)
language sql stable as $$
  with since as (select (extract(epoch from now())::bigint - p_days * 86400) as t),
  day_stats as (
    select public.local_day(ts) as d, count(distinct public.local_hour(ts)) as hours
      from public.agg_minute, since where ts >= since.t group by 1
  ),
  base as (
    select public.local_hour(ts) as hour,
           round(avg(pv_w)::numeric)   as pv_w,
           round(avg(load_w)::numeric) as load_w,
           -- HEAVY_LOAD_W = 1500: deferrable loads (geyser, kettle, oven, aircon, EV)
           -- are excluded so "spare solar" reflects genuine headroom.
           round(avg(case when load_w < 1500 then load_w end)::numeric) as baseline_load_w,
           round(avg(grid_w)::numeric) as grid_w,
           round(avg(soc)::numeric)    as soc,
           count(*)                    as samples
      from public.agg_minute, since
     where ts >= since.t
       and public.local_day(ts) in (select d from day_stats where hours >= 24)
     group by 1
  )
  select hour, pv_w, load_w,
         coalesce(baseline_load_w, load_w) as baseline_load_w,
         grid_w, soc, samples,
         round(coalesce(pv_w,0) - coalesce(load_w,0)) as surplus_w,
         round(coalesce(pv_w,0) - coalesce(coalesce(baseline_load_w, load_w),0)) as spare_w
    from base order by hour
$$;

-- ---------------------------------------------------------------------------
-- calSamples() — db.js:216. Un-curtailed daytime samples (battery not yet full,
-- so panels run free and actual PV ~ potential); calibrates the clear-sky line.
-- ---------------------------------------------------------------------------
create or replace function public.q_cal_samples()
returns table (ts bigint, pv_w integer, soc integer)
language sql stable as $$
  with day_stats as (
    select public.local_day(ts) as d, count(distinct public.local_hour(ts)) as hours
      from public.agg_minute group by 1
  )
  select a.ts, a.pv_w, a.soc from public.agg_minute a
   where a.pv_w > 800 and a.soc < 85
     and public.local_day(a.ts) in (select d from day_stats where hours >= 24)
$$;

-- ---------------------------------------------------------------------------
-- segmentPower() — db.js:241. Average power per day-segment with the load split
-- by source. The decomposition always reconciles to load:
--   solar->load = min(pv, load); rem = load - solar->load
--   batt->load  = discharging ? min(-batt, rem) : 0
--   grid->load  = rem - batt->load
-- so grid that charged the battery is correctly excluded.
-- ---------------------------------------------------------------------------
create or replace function public.q_segment_power(p_days integer default 7)
returns table (
  seg integer, load_w numeric, solar_w numeric, batt_w numeric, grid_w numeric, mins bigint)
language sql stable as $$
  with since as (select (extract(epoch from now())::bigint - p_days * 86400) as t),
  d as (
    select public.local_hour(ts) as h,
           coalesce(load_w, 0) as load,
           coalesce(batt_w, 0) as batt,
           least(coalesce(pv_w, 0), coalesce(load_w, 0)) as s2l
      from public.agg_minute, since where ts >= since.t
  ),
  e as (
    select h, load, s2l, (load - s2l) as rem,
           case when batt < 0 then least(-batt, load - s2l) else 0 end as b2l
      from d
  )
  select (case when h < 4 then 0 when h < 6 then 1 when h < 8 then 2
               when h < 17 then 3 else 4 end)::int as seg,
         round(avg(load)::numeric)       as load_w,
         round(avg(s2l)::numeric)        as solar_w,
         round(avg(b2l)::numeric)        as batt_w,
         round(avg(rem - b2l)::numeric)  as grid_w,
         count(*)                        as mins
    from e group by 1 order by 1
$$;

-- ---------------------------------------------------------------------------
-- dayAgg() — db.js:276. Day power series bucketed to ~5 min. feed_n/row_n expose
-- per-bucket provenance so cloud-recovered buckets render dotted.
-- ---------------------------------------------------------------------------
create or replace function public.q_day_agg(p_day date, p_source text default null)
returns table (
  hm text, pv_w numeric, load_w numeric, batt_w numeric, grid_w numeric,
  soc numeric, feed_n bigint, row_n bigint)
language sql stable as $$
  select to_char(public.local_ts(min(a.ts)), 'HH24:MI') as hm,
         round(avg(a.pv_w)::numeric)   as pv_w,
         round(avg(a.load_w)::numeric) as load_w,
         round(avg(a.batt_w)::numeric) as batt_w,
         round(avg(a.grid_w)::numeric) as grid_w,
         round(avg(a.soc)::numeric)    as soc,
         sum(case when a.source = 'plantfeed' then 1 else 0 end) as feed_n,
         count(*) as row_n
    from public.agg_minute a
   where public.local_day(a.ts) = p_day
     and (p_source is null or a.source = p_source)
   group by public.local_day(a.ts), public.local_hour(a.ts), public.local_minute(a.ts) / 5
   order by min(a.ts)
$$;

-- ---------------------------------------------------------------------------
-- missingMinutes() — db.js:299. The recovery work-list: minutes of a local day
-- with no row, clamped to [first row ever logged, now - 10 min]. The live edge
-- belongs to the poller — a cloud row on the current minute would block its INSERT.
-- ---------------------------------------------------------------------------
create or replace function public.q_missing_minutes(p_day date)
returns table (ts bigint)
language sql stable as $$
  with b as (
    select (select min(a.ts) from public.agg_minute a)          as first_ts,
           public.day_start_epoch(p_day)                        as day_start,
           extract(epoch from now())::bigint                    as now_ts
  ),
  bounds as (
    select ceil(greatest(day_start, first_ts) / 60.0)::bigint * 60 as lo,
           least(day_start + 86400, now_ts - 600)                  as hi
      from b where first_ts is not null
  )
  select g as ts from bounds, generate_series(bounds.lo, bounds.hi - 60, 60) g
   where bounds.hi > bounds.lo
     and not exists (select 1 from public.agg_minute a where a.ts = g)
$$;

-- ---------------------------------------------------------------------------
-- insertRecovered() — db.js:319. Banks cloud-recovered minutes. ON CONFLICT DO
-- NOTHING: a poller row always wins, recovery only ever fills holes. Returns the
-- number actually inserted. Fully reversible via
--   delete from agg_minute where source = 'plantfeed'
-- ---------------------------------------------------------------------------
create or replace function public.q_insert_recovered(p_rows jsonb)
returns integer
language plpgsql as $$
declare n integer;
begin
  with ins as (
    insert into public.agg_minute (ts, pv_w, load_w, batt_w, grid_w, soc, source)
    select (r->>'ts')::bigint,
           nullif(r->>'pv_w','')::integer,   nullif(r->>'load_w','')::integer,
           nullif(r->>'batt_w','')::integer, nullif(r->>'grid_w','')::integer,
           nullif(r->>'soc','')::integer,    'plantfeed'
      from jsonb_array_elements(p_rows) r
    on conflict (ts) do nothing
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;

-- recoveredMinutes() — db.js:335
create or replace function public.q_recovered_minutes(p_day date)
returns bigint language sql stable as $$
  select count(*) from public.agg_minute
   where source = 'plantfeed' and public.local_day(ts) = p_day
$$;

-- ---------------------------------------------------------------------------
-- dayGapMinutes() — db.js:346. Minutes of a local day the logger did NOT cover.
-- The expected window is the day clipped to [first row ever, now], so pre-logging
-- days return null and today only counts elapsed time.
-- ---------------------------------------------------------------------------
create or replace function public.q_day_gap_minutes(p_day date)
returns bigint language sql stable as $$
  with b as (
    select (select min(ts) from public.agg_minute)   as first_ts,
           public.day_start_epoch(p_day)             as day_start,
           extract(epoch from now())::bigint         as now_ts
  ),
  w as (
    select greatest(day_start, first_ts) as lo,
           least(day_start + 86400, now_ts) as hi
      from b where first_ts is not null
  )
  select case when w.hi <= w.lo then null
              else greatest(0, round((w.hi - w.lo) / 60.0)::bigint
                   - (select count(*) from public.agg_minute
                       where public.local_day(ts) = p_day))
         end
    from w
$$;

-- ---------------------------------------------------------------------------
-- Grants. These are internal primitives: Edge Functions (service_role) call them.
-- The frontend gets the endpoint-shaped RPCs added in a later migration, not these.
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'local_ts(bigint)', 'local_minute(bigint)', 'day_start_epoch(date)',
    'q_stats()', 'q_by_hour(integer)', 'q_cal_samples()', 'q_segment_power(integer)',
    'q_day_agg(date,text)', 'q_missing_minutes(date)', 'q_insert_recovered(jsonb)',
    'q_recovered_minutes(date)', 'q_day_gap_minutes(date)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
