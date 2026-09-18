-- The 18 September 2026 outage, and how to look at one again.
--
-- Eskom went off at 16:09 SAST and came back at 17:18:14, on plant 538820. It is the
-- first genuine dead grid this project measured, and it produced migrations 0055
-- (presence answers from the newest device_time, and grid_down loses its hedge), 0056
-- (grid_burst removed, its job done) and 0057 (grid_seen, so the off-grid plant can
-- announce a reconnection). The findings live in those headers and in FEATURES.md,
-- "Answered — grid presence". These are the queries that produced them.
--
-- Run them ONE AT A TIME — several statements in one file only shows you the last:
--
--     supabase db query --linked -o table -f scripts/sql/outage-2026-09-18.sql
--
-- `ts` on readings, strings and agg_minute is EPOCH SECONDS, not milliseconds. The
-- poll minute and the inverter's own device_time differ by up to a minute throughout,
-- which is the whole subject of 0055: at the 16:09 poll the master's device_time read
-- 16:08:46 and the slave's read 16:05:54, three minutes stale.
--
-- `grid_burst` appears in none of these. It was dropped in 0056 once the dead-grid and
-- reconnect questions were answered; production has no such table now.


-- ── 1. Presence, minute by minute, with the phases ──────────────────────────
-- The plain "was it off, and when" read. q_grid_present is the deployed function, so
-- this agrees with the Live chip and the alerts rather than re-deriving them. Any
-- minute where present is false is an outage minute.
select to_char(to_timestamp(r.ts) at time zone 'Africa/Johannesburg','MM-DD HH24:MI') as sast,
       public.q_grid_present(538820, r.ts)                       as present,
       max(r.grid_relay_status)                                  as relay,
       round(max(r.grid_volt_v)::numeric, 1)                     as l1,
       round(max(r.grid_volt_l2_v)::numeric, 1)                  as l2,      -- null unless three-phase
       round(max(r.grid_volt_l3_v)::numeric, 1)                  as l3,
       round(max(r.grid_freq_hz)::numeric, 2)                    as hz,
       round(sum(r.grid_w)::numeric, 0)                          as grid_w,
       round(max(r.output_volt_v)::numeric, 1)                   as out_v
  from public.readings r
 where r.plant_id = 538820
   and r.ts between extract(epoch from '2026-09-18 16:02:00'::timestamp at time zone 'Africa/Johannesburg')::bigint
                and extract(epoch from '2026-09-18 17:30:00'::timestamp at time zone 'Africa/Johannesburg')::bigint
 group by r.ts
 order by r.ts;


-- ── 2. Per inverter, with device_time — the staleness itself ─────────────────
-- Why the alert was late. The slave's rows for 16:08, 16:09 and 16:10 all carry
-- device_time 16:05:54 and a pre-outage 240.1 V, and the old bool_or let that frozen
-- sample report the grid present for two minutes after the master went dark. Watch
-- the device_time column stand still while ts advances.
select to_char(to_timestamp(ts) at time zone 'Africa/Johannesburg','HH24:MI') as sast,
       sn, carried, device_time,
       round(grid_volt_v::numeric, 1)  as l1,
       grid_relay_status               as relay
  from public.readings
 where plant_id = 538820
   and ts between extract(epoch from '2026-09-18 16:05:00'::timestamp at time zone 'Africa/Johannesburg')::bigint
                and extract(epoch from '2026-09-18 16:14:00'::timestamp at time zone 'Africa/Johannesburg')::bigint
 order by ts, sn;


-- ── 3. Is zero frequency a grid-absence signal? ─────────────────────────────
-- It looks like one and is not safe as one. Over a week this cross-tab shows zero-Hz
-- minutes falling entirely inside the outage, against thousands of relay-closed,
-- volts-up minutes at an average of a few tens of watts. The reason not to use it is
-- not in this output: grid_freq_hz arrives through extract.ts's `num()`, which turns
-- an absent field into 0, where grid_volt_v uses `numOrNull` and reads NULL. A dropped
-- field is a silent blackout on frequency and an honest unknown on voltage.
select grid_relay_status                as relay,
       (grid_volt_v > 100)              as volts_up,
       (grid_freq_hz = 0)               as hz_zero,
       count(*)                         as minutes,
       round(avg(abs(grid_w))::numeric, 0) as avg_abs_grid_w
  from public.readings
 where plant_id = 538820 and sn = '2508290475'
   and ts >= extract(epoch from now())::bigint - 7 * 86400
   and grid_volt_v is not null and grid_freq_hz is not null
 group by 1, 2, 3
 order by 1, 2, 3;


-- ── 4. Does a change to presence move anything but the minutes you expect? ──
-- The regression that made 0055 safe to ship: old rule against new, every minute of
-- the last week, both plants. When 0055 went out this showed 2 changed minutes in
-- 16,283 — the two stale ones — with nothing flipped the other way and nothing newly
-- unknown. Re-point `new_p` at whatever rule is being proposed and expect the same
-- shape of answer before deploying it.
with g as (
  select r.plant_id, r.ts, r.grid_volt_v, r.device_time,
         (r.grid_volt_v is not null) as has_v,
         max(r.device_time) filter (where r.grid_volt_v is not null)
           over (partition by r.plant_id, r.ts) as newest_dt
    from public.readings r
   where r.ts >= extract(epoch from now())::bigint - 7 * 86400
),
per_min as (
  select plant_id, ts,
         case when count(*) filter (where has_v) = 0 then null
              else bool_or(grid_volt_v > 100) filter (where has_v) end as old_p,
         case when count(*) filter (where has_v) = 0 then null
              else bool_or(grid_volt_v > 100)
                     filter (where has_v and device_time is not distinct from newest_dt) end as new_p
    from g group by plant_id, ts
)
select plant_id,
       count(*)                                                as minutes,
       count(*) filter (where old_p is not distinct from new_p) as agree,
       count(*) filter (where old_p is true  and new_p is false) as on_to_off,
       count(*) filter (where old_p is false and new_p is true)  as off_to_on,
       count(*) filter (where new_p is null) - count(*) filter (where old_p is null) as extra_unknown
  from per_min
 group by plant_id
 order by plant_id;


-- ── 5. Per-string history for a day ─────────────────────────────────────────
-- Not about the grid: this is the read behind the string "check" light, which showed
-- MPPT input 1 has never produced on either inverter. Kept because an outage day is
-- exactly when strings look wrong for reasons that are not faults.
select to_char(to_timestamp(ts) at time zone 'Africa/Johannesburg','HH24:MI') as sast,
       sn, no, volt_v, current_a, power_w
  from public.strings
 where plant_id = 538820
   and ts >= extract(epoch from '2026-09-18'::date)::bigint
   and ts <  extract(epoch from '2026-09-19'::date)::bigint
 order by ts, sn, no;
