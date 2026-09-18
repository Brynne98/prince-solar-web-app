-- ============================================================================
-- Tell me when the off-grid plant reconnects, because nothing else will.
--
-- Plant 495944 is three-phase -- all three of its inverters report L1, L2 and L3
-- -- and it runs the house off its 115 kWh of batteries. Over its whole history
-- in this database, 22,526 rows since 12 Sep, grid voltage has never exceeded
-- 0.0 V on any phase and grid_relay_status has never once read '1'. Its owners do
-- put it back on the grid from time to time, and that is the only event that can
-- produce a three-phase grid-live sample to test phase detection against.
--
-- THE CATCH. plant_config.has_grid is false for it, detected from readings, and
-- 0042's api_alerts_due wrapper uses that to suppress grid_down and grid_back.
-- plant_features_detect will flip it to true on its own, but only once a
-- reconnection is already sitting in the last 24 h of non-carried rows. So the
-- first reconnection is precisely the event that cannot notify anyone about
-- itself, and it would be found days later by someone querying for it.
--
-- `grid_seen` is not in that filter, so it fires while has_grid is still false
-- and goes quiet once detection catches up and makes it true. It tests ANY of the
-- three phases, not grid_volt_v alone, because a three-phase supply can return a
-- leg at a time -- and because the L1-only habit is exactly the bug FEATURES.md
-- records against phase_down.
--
-- Everything else in this function is 0055's body, unchanged.
-- ============================================================================

create or replace function public.api_alerts_due_raw(p_plant bigint)
returns table (kind text, key text, level text, title text, body text, value double precision)
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  with
  pz as (select public.plant_tz(p_plant) as tz),
  now_s as (select extract(epoch from now())::bigint as t),
  loc as (
    select timezone((select tz from pz), now()) as ts,
           (timezone((select tz from pz), now()))::date as day,
           extract(hour from timezone((select tz from pz), now()))::int as hour
  ),
  hour_key as (select to_char(date_trunc('hour', timezone((select tz from pz), now())), 'YYYY-MM-DD"T"HH24') as k),
  health as (select h.j->>'stale' = 'true' as stale, (h.j->>'ageSeconds')::double precision as age_s from (select public.api_health(p_plant) as j) h),
  bal as (select public.api_balance(p_plant) as j),
  batt_cfg as (select coalesce(c.battery_kwh, 0) as pack_kwh, coalesce(c.battery_reserve_pct, 20) as reserve_pct from public.plant_cfg(p_plant) c),
  night_win as (
    select a.ts, a.soc, timezone((select tz from pz), to_timestamp(a.ts)) as lts,
           (select percentile_cont(0.5) within group (order by b.batt_w::double precision)
              from public.agg_minute b where b.plant_id = p_plant and b.ts > a.ts - 3600 and b.ts <= a.ts and b.batt_w is not null) as draw_w
      from public.agg_minute a, now_s where a.plant_id = p_plant and a.ts > now_s.t - 1800
  ),
  night_calc as (
    select w.ts,
      case when extract(hour from w.lts)::int < 6 then w.lts::date - 1 else w.lts::date end as night_day,
      case when extract(hour from w.lts)::int >= 18 then extract(epoch from ((w.lts::date + 1) + time '06:00') - w.lts) / 3600.0
           when extract(hour from w.lts)::int < 6 then extract(epoch from (w.lts::date + time '06:00') - w.lts) / 3600.0
           else null end as hrs_to_sunrise,
      case when w.draw_w < -50 and c.pack_kwh > 0
           then greatest(0.0, (coalesce(w.soc, 0) - c.reserve_pct) / 100.0 * c.pack_kwh) / (abs(w.draw_w) / 1000.0)
           else null end as hrs_left
      from night_win w, batt_cfg c
  ),
  overnight as (
    select (array_agg(night_day order by ts desc))[1] as night_day, (array_agg(hrs_left order by ts desc))[1] as hrs_left,
           count(*) as n, bool_and(hrs_left is not null and hrs_left < hrs_to_sunrise) as sustained
      from night_calc where hrs_to_sunrise is not null
  ),
  grid_min as (select r.ts, public.q_grid_present(p_plant, r.ts) as present from (select distinct ts from public.readings, now_s where plant_id = p_plant and ts >= now_s.t - 1800) r),
  -- Minutes where presence is unknown are skipped rather than counted against
  -- the debounce: a poll that timed out is not evidence the grid is up.
  grid_known as (select ts, present from grid_min where present is not null),
  newest3 as (select present from grid_known order by ts desc limit 3),
  grid as (
    select (select present from grid_known order by ts desc limit 1) as latest,
           (select count(*) from newest3) as known3,
           (select bool_and(present is false) from newest3) as newest3_false,
           (select count(*) from grid_known, now_s where ts >= now_s.t - 1800 and present is false) as false_30m,
           (select count(*) from grid_known, now_s where ts >= now_s.t - 120 and present is false) as false_2m
  ),
  str_latest as (select max(ts) as ts from public.strings where plant_id = p_plant),
  dead_held as (
    select s.sn, s.no from public.strings s, loc, now_s
     where s.plant_id = p_plant and loc.hour between 11 and 14 and s.ts >= now_s.t - 900
       and coalesce(s.volt_v, 0) < 1.5 and coalesce(s.power_w, 0) < 5
       and exists (select 1 from public.strings o where o.plant_id = p_plant and o.ts = s.ts and o.sn = s.sn and o.no is distinct from s.no and coalesce(o.power_w, 0) > 200)
     group by s.sn, s.no
    having count(*) >= 12
       and exists (select 1 from public.strings cur, str_latest where cur.plant_id = p_plant and cur.ts = str_latest.ts and cur.sn = s.sn and cur.no = s.no and coalesce(cur.volt_v, 0) < 1.5 and coalesce(cur.power_w, 0) < 5)
  ),
  dead as (select count(*)::int as n, string_agg('string ' || d.no::text || coalesce(' on ' || nullif(m.alias, ''), ''), ', ' order by m.alias, d.no) as which
             from dead_held d left join private.meta m on m.sn = d.sn)
  select 'logger_stale', 'logger_stale:' || (select k from hour_key), 'urgent', 'Solar logger stopped',
         'No data for ' || greatest(1, round(age_s / 60.0))::int || ' minutes', age_s from health where stale
  union all
  select 'bank_drift', 'bank_drift:' || (select k from hour_key), 'urgent', 'Battery banks drifting',
         coalesce(round((j->>'socSpread')::numeric, 0)::text, '?') || '% apart for 10 minutes', (j->>'socSpread')::double precision from bal where j->>'status' = 'drifting'
  union all
  select 'batt_hot', 'batt_hot:' || (select day from loc)::text, 'urgent', 'Battery is hot · ' || round((j->>'tempC')::numeric, 0)::text || '°C', '', (j->>'tempC')::double precision from bal where (j->>'tempHot')::boolean is true
  union all
  select 'soc_overnight', 'soc_overnight:' || night_day::text, 'urgent', 'Battery won''t last the night',
         floor(hrs_left)::int || 'h ' || lpad(round((hrs_left - floor(hrs_left)) * 60)::int::text, 2, '0') || 'm left at tonight''s draw', hrs_left
    from overnight where sustained and n >= 25
  union all
  -- No relay term and no hedge: no mains voltage for three known minutes is an
  -- outage, whichever side of the relay the inverter has put itself on.
  select 'grid_down', 'grid_down:' || (select k from hour_key), 'urgent', 'Grid is off', '', null
    from grid where latest is false and known3 >= 3 and newest3_false
  union all
  select 'grid_back', 'grid_back:' || (select k from hour_key), 'urgent', 'Grid is back', '', null
    from grid where latest is true and false_2m = 0 and false_30m >= 3
  union all
  -- A plant we have recorded as off-grid just showed mains voltage on some leg.
  -- Fires on ANY phase, because a three-phase plant can come back a leg at a
  -- time, and deliberately not on grid_volt_v alone. Day-keyed: this is a "go
  -- and look" notice, not an emergency.
  --
  -- It exists because has_grid gates the other grid alerts (0042's wrapper), and
  -- plant_features_detect only flips it once a reconnection is already in the
  -- last 24 h of rows -- so the FIRST reconnection is the one event that cannot
  -- announce itself. This is the kind that can, by not being in that filter.
  select 'grid_seen', 'grid_seen:' || (select day from loc)::text, 'digest',
         'Plant is on the grid',
         'First mains voltage here — the grid alerts switch on by themselves',
         (select max(greatest(r.grid_volt_v, r.grid_volt_l2_v, r.grid_volt_l3_v))
            from public.readings r, now_s
           where r.plant_id = p_plant and r.ts >= now_s.t - 1800)
    from public.plant_config c, now_s
   where c.plant_id = p_plant
     and c.has_grid is not true
     and exists (
       select 1 from public.readings r
        where r.plant_id = p_plant and r.ts >= now_s.t - 1800
          and greatest(r.grid_volt_v, r.grid_volt_l2_v, r.grid_volt_l3_v) > 100)
  union all
  select 'string_dead', 'string_dead:' || (select day from loc)::text, 'digest',
         case when n = 1 then 'A solar string looks dead' else n::text || ' solar strings look dead' end,
         which || ' — no voltage, sibling still producing', n::double precision from dead where n > 0
$$;
