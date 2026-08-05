-- ============================================================================
-- Endpoint-shaped RPCs — what the frontend actually calls.
--
-- Each returns JSON byte-identical to the matching Express endpoint (shapes in
-- API.md), so public/data.jsx's mapping layer needs no changes: only the transport
-- swaps from `GET /api/x` to `POST /rest/v1/rpc/api_x`.
--
-- EXECUTE goes to `authenticated` only — this is the sole read surface the browser
-- has, and the anon key that ships in the public bundle cannot call any of it.
--
-- NOT ported: /api/debug/:sn (proxies live to SunSynk; must never be public).
-- Deferred until sync-plant-energy exists: energy, trends/daily, trends/monthly,
-- trends/compare, history/earliest — all need SunSynk's plant-level history, which
-- predates the local logger.
-- ============================================================================

-- bucket index -> "HH:MM"
create or replace function public._hm(bkt int)
returns text language sql immutable parallel safe as $$
  select lpad((bkt / 12)::text, 2, '0') || ':' || lpad(((bkt % 12) * 5)::text, 2, '0')
$$;

-- ---------------------------------------------------------------------------
-- GET /api/db/stats. `raw` was intentionally not migrated, so its counters are 0.
-- ---------------------------------------------------------------------------
create or replace function public.api_db_stats()
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'aggRows', s.agg_rows, 'days', s.days,
    'first', case when s.first_ts is null then null
                  else to_char(to_timestamp(s.first_ts) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') end,
    'last',  case when s.last_ts is null then null
                  else to_char(to_timestamp(s.last_ts) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') end,
    'perInverterRows', s.per_inverter_rows,
    'rawSnapshots', 0, 'rawBytesUncompressed', 0, 'rawBytesGzipped', 0)
  from public.q_stats() s
$$;

-- GET /api/trends/by-hour?days=
create or replace function public.api_trends_by_hour(p_days integer default 14)
returns jsonb language sql stable as $$
  select jsonb_build_object('days', p_days,
    'hours', coalesce((select jsonb_agg(to_jsonb(h) order by h.hour) from public.q_by_hour(p_days) h), '[]'::jsonb))
$$;

-- GET /api/trends/segments?days=
create or replace function public.api_trends_segments(p_days integer default 7)
returns jsonb language sql stable as $$
  select jsonb_build_object('days', p_days,
    'segments', coalesce((select jsonb_agg(to_jsonb(s) order by s.seg) from public.q_segment_power(p_days) s), '[]'::jsonb))
$$;

-- ---------------------------------------------------------------------------
-- GET /api/history?date=
--
-- Re-grids the day onto all 288 five-minute buckets so minutes the logger missed
-- become explicit null points — the chart breaks/shades them rather than drawing a
-- line across the gap. Buckets built purely from cloud-recovered rows are flagged
-- `est` so provenance survives recovery.
--
-- The Express version can opportunistically call recoverDay() here; that belongs to
-- the `recover` Edge Function on its own schedule, so this stays read-only.
-- ---------------------------------------------------------------------------
create or replace function public.api_history(p_date date default null)
returns jsonb language sql stable as $$
  with d as (
    select coalesce(p_date, (now() at time zone 'Africa/Johannesburg')::date) as day
  ),
  agg as (
    select (split_part(a.hm, ':', 1)::int) * 12 + (split_part(a.hm, ':', 2)::int / 5) as bkt,
           a.pv_w, a.batt_w, a.grid_w, a.load_w, a.soc, a.feed_n, a.row_n
      from d, public.q_day_agg(d.day, null) a
  ),
  n as (select count(*) as c, coalesce(max(bkt), 0) as mx from agg),
  lastb as (
    -- past days span midnight to midnight; today stops at the latest logged bucket
    select case when (select day from d) = (now() at time zone 'Africa/Johannesburg')::date
                then (select mx from n) else 287 end as lb
  ),
  buckets as (
    select g.i as bkt, a.pv_w, a.batt_w, a.grid_w, a.load_w, a.soc, a.feed_n, a.row_n
      from lastb, generate_series(0, (select lb from lastb)) as g(i)
      left join agg a on a.bkt = g.i
  ),
  defs as (
    select * from (values
      ('PV', 'W', 'pv', 1),
      -- legacy chart convention (- = charging); storage is + = charging.
      -- This is the ONLY sign flip in the codebase.
      ('Battery', 'W', 'battflip', 2),
      ('Grid', 'W', 'grid', 3),
      ('Load', 'W', 'load', 4),
      ('SOC', '%', 'soc', 5)
    ) as t(label, unit, field, ord)
  )
  select case when (select c from n) <= 5
    -- Express falls back to the SunSynk cloud feed for days before logging started.
    -- Those days are pre-history here; return an empty series rather than a partial one.
    then jsonb_build_object('date', (select day from d)::text, 'series', '[]'::jsonb, 'approx', true)
    else jsonb_build_object(
      'date', (select day from d)::text,
      'gapMinutes', public.q_day_gap_minutes((select day from d)),
      'recoveredMinutes', public.q_recovered_minutes((select day from d)),
      'series', (
        select jsonb_agg(ser order by ord) from (
          select f.ord, jsonb_build_object('label', f.label, 'unit', f.unit, 'points', (
            select jsonb_agg(
              jsonb_build_object('time', public._hm(b.bkt), 'value',
                case when b.row_n is null then null
                     when f.field = 'pv'       then coalesce(b.pv_w, 0)
                     when f.field = 'battflip' then -coalesce(b.batt_w, 0)
                     when f.field = 'grid'     then coalesce(b.grid_w, 0)
                     when f.field = 'load'     then coalesce(b.load_w, 0)
                     else b.soc end)
              || case when b.row_n is not null and b.feed_n > 0 and b.feed_n >= b.row_n
                      then jsonb_build_object('est', true) else '{}'::jsonb end
              order by b.bkt)
            from buckets b)) as ser
          from defs f) x))
    end
$$;

-- ---------------------------------------------------------------------------
-- GET /api/balance — bank desync signal plus the battery-longevity numbers.
-- ---------------------------------------------------------------------------
create or replace function public.api_balance()
returns jsonb language sql stable as $$
  with now_s as (select extract(epoch from now())::bigint as t),
  bal as (
    -- glitch filter: both banks must report a plausible 1-100% SOC, and a real
    -- spread can't exceed 25 points in a tick (that's a bad poll, not a drift)
    select r.ts,
           max(r.batt_soc) - min(r.batt_soc) as socspread,
           max(r.batt_voltage_v) - min(r.batt_voltage_v) as vspread
      from public.readings r, now_s
     where r.ts >= now_s.t - 72 * 3600
       and r.batt_soc is not null and r.batt_soc between 1 and 100
     group by r.ts
    having count(distinct r.sn) = 2 and (max(r.batt_soc) - min(r.batt_soc)) <= 25
  ),
  last_r as (select * from bal order by ts desc limit 1),
  -- SUSTAINED status: the spread must stay elevated for a continuous ~10 min before
  -- flagging, so banks briefly spreading during a hard charge don't trip the banner.
  -- One dip below the band resets it, hence MIN across the window.
  win as (
    select count(*) >= 2 and (max(ts) - min(ts)) >= 9 * 60 as have_window,
           min(socspread) as min_spread
      from bal, now_s where bal.ts >= now_s.t - 600
  ),
  spreads as (
    select (select round(socspread * 10) / 10 from last_r) as soc_spread,
           (select round(vspread * 100) / 100 from last_r) as v_spread
  ),
  st as (
    select case when s.soc_spread is null then 'unknown'
                when not coalesce(w.have_window, false) then 'balanced'
                when w.min_spread >= 5 then 'drifting'
                when w.min_spread >= 3 then 'watch'
                else 'balanced' end as status,
           case when s.soc_spread is null then 'unknown'
                when s.soc_spread < 3 then 'balanced'
                when s.soc_spread < 5 then 'watch'
                else 'drifting' end as live_band,
           s.soc_spread, s.v_spread
      from spreads s, win w
  ),
  health as (
    select (select batt_temp_c from public.readings
             where batt_temp_c > 0 and batt_temp_c < 80 order by ts desc limit 1) as temp_c,
           (select coalesce(round(sum(case when soc >= 98 then 1 else 0 end) / 60.0, 1), 0)
              from public.agg_minute
             where public.local_day(ts) = (now() at time zone 'Africa/Johannesburg')::date) as hrs_full
  )
  select jsonb_build_object(
    'banks', coalesce((select jsonb_agg(jsonb_build_object(
                'sn', sn, 'soc', batt_soc, 'voltage', batt_voltage_v, 'current', batt_current_a)
              order by sn)
              from public.readings
             where ts = (select max(ts) from public.readings where batt_soc is not null)), '[]'::jsonb),
    'socSpread', st.soc_spread,
    'vSpread', st.v_spread,
    'status', st.status,
    'pending', st.live_band not in ('unknown', 'balanced') and st.status = 'balanced',
    'max24h', (select round(max(socspread) * 10) / 10 from bal, now_s where bal.ts >= now_s.t - 24 * 3600),
    'max72h', (select round(max(socspread) * 10) / 10 from bal),
    'samples', (select count(*) from bal),
    'tempC', h.temp_c,
    'hrsAtFullToday', h.hrs_full,
    'tempHot', h.temp_c is not null and h.temp_c > 35,  -- LFP ageing climbs above ~35C
    'stale', (select ts from last_r) is null
             or ((select t from now_s) - (select ts from last_r)) > 600)
  from st, health h
$$;

-- ---------------------------------------------------------------------------
-- Clear-sky solar model, ported from server.js clearSkyShape(). Pure geometry:
-- relative plane-of-array output, 0..1. Constants match the server defaults
-- (Johannesburg, 25 deg tilt, due north, 12.6 kWp, DNI base 0.82).
-- ---------------------------------------------------------------------------
create or replace function public.clear_sky_shape(p_ts bigint)
returns double precision language sql immutable parallel safe as $$
  with c as (
    select -26.2041::double precision as lat, 25::double precision as tilt,
           0::double precision as azimuth, 0.82::double precision as dni_base,
           public.local_ts(p_ts) as d
  ),
  g as (
    select radians(23.45 * sin(radians(360 * (284 + extract(doy from d)::int) / 365.0))) as decl,
           radians(15 * ((extract(hour from d) * 60 + extract(minute from d)) / 60.0 - 12)) as w,
           radians(lat) as phi, radians(tilt) as b, radians(azimuth) as gz, dni_base
      from c
  ),
  s as (
    select -cos(decl) * sin(w) as se,
           cos(phi) * sin(decl) - sin(phi) * cos(decl) * cos(w) as sn,
           sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(w) as su,
           sin(b) * sin(gz) as ne, sin(b) * cos(gz) as nn, cos(b) as nu, dni_base
      from g
  )
  select case when su <= 0 then 0  -- sun below horizon
              else power(dni_base, power(1 / greatest(0.05, su), 0.678))  -- air-mass attenuation
                   * greatest(0, se * ne + sn * nn + su * nu)
         end
    from s
$$;

-- solarScaleW() — calibrate the clear-sky scale from un-curtailed samples. Uses the
-- same index arithmetic as the JS (sorted[floor(n * 0.95)]) rather than
-- percentile_disc, so the two agree exactly.
create or replace function public.solar_scale_w()
returns integer language sql stable as $$
  with ratios as (
    select c.pv_w / public.clear_sky_shape(c.ts) as r
      from public.q_cal_samples() c
     where public.clear_sky_shape(c.ts) > 0.25
  ),
  n as (select count(*) as c from ratios),
  picked as (
    select r from ratios, n where n.c >= 20 order by r offset (select floor(c * 0.95)::int from n) limit 1
  )
  -- fallback until there's enough data, then cap at 1.5x nameplate
  select round(least(coalesce((select r from picked), 12.6 * 1000 * 0.82), 12.6 * 1000 * 1.5))::int
$$;

-- GET /api/trends/potential?date=
create or replace function public.api_trends_potential(p_date date default null)
returns jsonb language sql stable as $$
  with d as (select coalesce(p_date, (now() at time zone 'Africa/Johannesburg')::date) as day),
  s as (select public.solar_scale_w() as scale),
  day0 as (select public.day_start_epoch((select day from d)) as t0)
  select jsonb_build_object(
    'date', (select day from d)::text,
    'scaleW', (select scale from s),
    'points', coalesce((
      select jsonb_agg(jsonb_build_object(
               't', t,
               'w', round((select scale from s) * public.clear_sky_shape((select t0 from day0) + t * 60))) order by t)
        from generate_series(0, 1435, 5) t), '[]'::jsonb))
$$;

-- ---------------------------------------------------------------------------
-- Grants.
--
-- The api_* surface is the browser's only read path, so EXECUTE goes to
-- `authenticated`. The read-only q_* primitives they call need the same grant
-- (a non-SECURITY-DEFINER function runs with the caller's rights). The two q_*
-- that write or drive recovery — q_missing_minutes, q_insert_recovered — stay
-- service_role-only, as set in migration 0003.
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'api_db_stats()', 'api_trends_by_hour(integer)', 'api_trends_segments(integer)',
    'api_history(date)', 'api_balance()', 'api_trends_potential(date)',
    '_hm(integer)', 'clear_sky_shape(bigint)', 'solar_scale_w()',
    -- read-only primitives reached through the api_* wrappers
    'q_stats()', 'q_by_hour(integer)', 'q_segment_power(integer)', 'q_day_agg(date,text)',
    'q_day_gap_minutes(date)', 'q_recovered_minutes(date)', 'q_cal_samples()',
    'local_ts(bigint)', 'local_minute(bigint)', 'day_start_epoch(date)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
