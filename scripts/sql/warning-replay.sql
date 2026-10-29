-- Warning replay (SOLAR-231): every time each warning would have shown over the readings
-- still held (31 days), per plant, and for how long. Reads only.
--   supabase db query --linked -o table -f scripts/sql/warning-replay.sql
-- A run of one or two minutes is most likely noise, not a real fault: the `short` column
-- counts them. Rules are the ones in force, copied here; when a rule changes, change it here.
-- Limits: a minute with no stored row is not counted (the poller writes nothing while
-- SunSynk is unreachable), so quiet spells show only while other rows arrive; unknown grid
-- minutes are skipped, as the email does; hot_email ignores the 43 °C release and 3-minute
-- hold, so a battery hovering near 45 °C shows more runs than emails sent.
--   quiet       an inverter's newest reading over 15 min old (data.jsx READ_FRESH_MS)
--   grid_off    over 100 V nowhere among the rows with the newest device_time (0089, 0103)
--   grid_unknown no voltage reported at all
--   phase_down  grid present and a second or third leg under 100 V (0089)
--   hot_app     hottest reading battery over 45 °C (tabs.jsx equipmentState)
--   hot_email   hottest battery, rounded, over 45 °C, 0-80 °C kept (0119; the email waits 3 min)
--   zero_batt   a battery stored as 0 % and 0 °C: an empty SunSynk answer (stored as unknown since 0119's poll)
with r as (
  select r.plant_id, r.ts, r.sn, r.grid_volt_v, r.grid_volt_l2_v, r.grid_volt_l3_v, r.batt_temp_c, r.batt_soc,
         case when r.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
              then extract(epoch from (r.device_time::timestamp at time zone public.plant_tz(r.plant_id)))::bigint end as dev
    from public.readings r
), newest as (
  select plant_id, ts, max(dev) filter (where grid_volt_v is not null) as dt from r group by plant_id, ts
), minute as (
  select r.plant_id, r.ts,
         case when count(r.grid_volt_v) = 0 then null
              else coalesce(bool_or(r.grid_volt_v > 100) filter (where r.grid_volt_v is not null and r.dev is not distinct from n.dt), false) end as present,
         bool_or(r.grid_volt_v > 100 and least(coalesce(r.grid_volt_l2_v, 999), coalesce(r.grid_volt_l3_v, 999)) < 100) as phase_down,
         max(r.batt_temp_c) filter (where r.batt_temp_c > -50 and r.batt_temp_c <= 120) as temp_app,
         round(max(r.batt_temp_c) filter (where r.batt_temp_c > 0 and r.batt_temp_c < 80)) as temp_email,
         bool_or(r.batt_soc = 0 and r.batt_temp_c = 0) as zero_batt
    from r join newest n using (plant_id, ts)
   group by r.plant_id, r.ts
), inv as (
  -- per inverter: the newest reading time it has given by this minute
  select plant_id, sn, ts, max(dev) over (partition by plant_id, sn order by ts) as last_dev from r
), flags as (
  select plant_id, null::text as sn, ts, 'grid_off' as rule, not present as on_ from minute where present is not null
  union all select plant_id, null, ts, 'grid_unknown', present is null from minute
  union all select plant_id, null, ts, 'phase_down', coalesce(phase_down, false) from minute
  union all select plant_id, null, ts, 'hot_app', coalesce(temp_app > 45, false) from minute
  union all select plant_id, null, ts, 'hot_email', coalesce(temp_email > 45, false) from minute
  union all select plant_id, null, ts, 'zero_batt', coalesce(zero_batt, false) from minute
  union all select plant_id, sn, ts, 'quiet', last_dev is null or ts - last_dev > 900 from inv
), runs as (
  -- a run: consecutive stored minutes with the rule on. Like the email's count, it steps
  -- over minutes with no row and the unknown grid minutes dropped above.
  select plant_id, sn, rule, ts, on_,
         row_number() over (partition by plant_id, sn, rule order by ts)
           - row_number() over (partition by plant_id, sn, rule, on_ order by ts) as grp
    from flags
), episodes as (
  select plant_id, sn, rule, count(*) as mins, min(ts) as start
    from runs where on_ group by plant_id, sn, rule, grp
)
select plant_id, coalesce(sn, '') as sn, rule, count(*) as episodes, sum(mins) as minutes,
       count(*) filter (where mins <= 2) as short, max(mins) as longest,
       to_char(to_timestamp(max(start)) at time zone public.plant_tz(plant_id), 'MM-DD HH24:MI') as last_start
  from episodes
 group by plant_id, sn, rule
 order by plant_id, rule, sn;
