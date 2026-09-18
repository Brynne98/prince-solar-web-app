-- ============================================================================
-- A stale inverter may no longer out-vote a fresh one, and "grid off" stops
-- hedging. Both from the first dead grid this project has actually measured.
--
-- MEASURED 2026-09-18, mains down from 16:09 SAST across two plants, five
-- inverters. While the utility was genuinely dead, every inverter read
-- grid_freq_hz 0.00 and grid_relay_status '0'. grid_volt_v read exactly 0.0 on
-- plant 495944's three, and 15.2 V decaying to 7.3 V over 37 minutes on
-- 538820's master with 5.5 V on its slave -- residual, far under the 100 V
-- floor. Output stayed live at 217-230 V on all five. So 0015's premise holds:
-- grid voltage collapses when the supply fails, and the `> 100` test is sound.
-- The open question in 0017's header is closed, and 0029's burst answered it.
--
-- FREQUENCY IS NOT THE TEST EITHER, but not for the reason first written here.
-- The restoration was captured too: at 17:18:14 grid_volt_v jumped 6.6 -> 241.0 V
-- and grid_freq_hz 0.00 -> 49.86 in the SAME sample, with the relay still '0' and
-- no current flowing, and it stayed that way for 92 s until the relay closed at
-- 17:20:06. So frequency is measured on the grid side, not the inverter side, and
-- it returns with the mains rather than with the relay. Cross-tabulated over the
-- last seven days on the master, grid_freq_hz = 0 in fact tracks grid absence
-- almost exactly: 70 zero-Hz minutes, every one of them this outage, against
-- 8,741 minutes of relay closed / volts up / non-zero Hz at an average of just
-- 32 W across the CT. 0015's "54% of all minutes read zero frequency" was true of
-- the history logged up to Aug 2026 -- commissioning and off-grid running -- and
-- is not a statement about how this firmware behaves now.
--
-- It is still the wrong column to test, for one reason that has nothing to do with
-- the physics: grid_freq_hz arrives through extract.ts's `num()`, which turns an
-- absent or unparseable field into 0, while grid_volt_v uses `numOrNull` so the
-- same hiccup reads NULL. A dropped field would be a silent blackout on frequency
-- and an honest "unknown" on voltage. The 2026-09-04 11:15 minute is the matching
-- observation: 0.00 Hz alongside 242.9 V for a single minute as the inverter
-- tripped and before it re-locked. Voltage stays the test. Frequency is worth
-- storing and is fair corroboration, but nothing should branch on it alone.
--
-- WHAT ACTUALLY DELAYED TODAY'S ALERT was neither. 538820's slave datalogger
-- uploads about every five minutes, so its stored rows for 16:08, 16:09 and
-- 16:10 all carried device_time frozen at 16:05:54 with a pre-outage
-- grid_volt_v of 240.1 (carried = true; the poller's carry is working as
-- designed). Presence was `bool_or(grid_volt_v > 100)` over every row at the
-- minute, so that one frozen sample reported "grid present" for two minutes
-- after the master had already dropped to 15.2 V with its relay open.
-- Presence only turned false at 16:11, and `false_3m >= 3` then held the alert
-- back to about 16:13 -- four minutes of darkness before the phone buzzed.
--
-- THE RULE THIS INSTALLS: the newest reading decides. Each row's device_time
-- names the moment its voltage describes, so the rows carrying the newest
-- device_time at a minute are the newest evidence about the grid, and older rows
-- are not evidence against them -- they are evidence about an earlier moment.
-- Presence is `bool_or(grid_volt_v > 100)` over those rows alone. At 16:09 the
-- master's 16:08:46 sample outranks the slave's 16:05:54 one, so the frozen
-- 240.1 V does not get a vote and presence is false the minute mains died.
--
-- No upload cadence is guessed, no staleness threshold is picked, and no
-- plant-local timestamp is parsed: device_time is text in 'YYYY-MM-DD HH24:MI:SS'
-- shape, and within one plant at one minute its lexicographic order is its
-- chronological order, which is all the comparison needs.
--
-- The rejected alternative was "ignore a row whose device_time repeats its own
-- previous row, and fall back to every row when none is fresh". It flips presence
-- back to true mid-outage. The master's device_time repeats on 10.8% of minutes
-- (949 of 8,823 over the last seven days) because it uploads about every 67 s
-- against a 60 s poll, so during the five minutes before the slave's first
-- post-outage upload there is roughly a one-in-nine chance per minute that NO row
-- is fresh -- and the fallback then hands the vote straight back to the slave's
-- frozen 240.1 V. Ranking by device_time has no such hole: a master sample one
-- minute old still outranks a slave sample four minutes old.
--
-- A single-inverter plant, and a plant whose only datalogger uploads every five
-- minutes, both work unchanged: their one row is trivially the newest. An
-- inverter whose grid call failed reports no voltage at all and so cannot win the
-- vote, which lets a healthy sibling answer for the plant.
--
-- AND THE WORDING LOSES ITS HEDGE. 0017 split grid_down in two, confident when
-- the relay was still closed and "Grid may be off ... unconfirmed" when it was
-- open, because nobody knew whether voltage merely tracked the relay. It does
-- not -- but anti-islanding opens the relay within seconds of losing mains, so
-- a real blackout always reads relay '0'. Today's genuine outage returned the
-- unconfirmed wording from all five inverters. The confident branch was the
-- unreachable one. There is now a single "Grid is off", the relay is out of the
-- test entirely, and with it goes a `limit 1` with no `order by` that picked
-- one inverter's relay status arbitrarily.
--
-- The debounce stays at three minutes -- deliberate relay-open stretches never
-- read under 100 V, so they were never the thing it was guarding -- but it now
-- counts the three newest minutes with a KNOWN answer rather than three clock
-- slots inside a 180-second window. With roughly a third of polls still timing
-- out on the free quota, one lost minute used to postpone the alert by a whole
-- minute for no reason.
-- ============================================================================

-- ── presence ────────────────────────────────────────────────────────────────
create or replace function public.q_grid_present(p_plant bigint, p_ts bigint)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  with voters as (
    select grid_volt_v, device_time
      from public.readings
     where plant_id = p_plant
       and ts = p_ts
       and grid_volt_v is not null
  ),
  newest as (
    -- NULL device_time cannot be dated, so it never wins. When every voter is
    -- undated -- readings from before 0031 stored device_time -- max() is NULL
    -- and the `is not distinct from` below lets them all vote, which is the old
    -- behaviour and the only thing left to do with them.
    select max(device_time) as dt from voters
  )
  select case when not exists (select 1 from voters) then null
              else (select bool_or(v.grid_volt_v > 100)
                      from voters v
                     where v.device_time
                           is not distinct from (select dt from newest)) end
$$;

comment on function public.q_grid_present(bigint, bigint) is
  'Is the utility supply present at this minute? Grid voltage over 100 V among the '
  'rows carrying the newest device_time, so a datalogger that has not uploaded '
  'cannot out-vote one that has. NULL when no voltage was reported at all.';

-- ── alerts ──────────────────────────────────────────────────────────────────
-- Body reproduced from 0042 with the grid CTEs and the grid_down branch
-- replaced; `relay` is gone. Replacing the _raw body leaves 0042's
-- public.api_alerts_due wrapper, and its has_grid / has_battery filters, intact.
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
  select 'string_dead', 'string_dead:' || (select day from loc)::text, 'digest',
         case when n = 1 then 'A solar string looks dead' else n::text || ' solar strings look dead' end,
         which || ' — no voltage, sibling still producing', n::double precision from dead where n > 0
$$;
