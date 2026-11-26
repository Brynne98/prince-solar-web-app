CREATE OR REPLACE FUNCTION public.email_plant_events(p_plant bigint)
 RETURNS TABLE(kind text, key text, data jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with
  pz as (select public.plant_tz(p_plant) as tz),
  now_s as (select extract(epoch from now())::bigint as t),
  cfg as (select coalesce((select has_grid from plants.settings where plant_id = p_plant), true) as has_grid,
                 coalesce((select has_battery from plants.settings where plant_id = p_plant), true) as has_battery,
                 (select battery_banks from plants.settings where plant_id = p_plant) as banks),
  loc as (select public.today_tz((select tz from pz)) as day,
                 extract(hour from timezone((select tz from pz), now()))::int as hour),
  day_lo as (select public.day_start_epoch_tz((select day from loc), (select tz from pz)) as lo),

  -- Grid. Minutes where presence is unknown are skipped, as in 0057.
  grid_known as (
    select r.ts, public.q_grid_present(p_plant, r.ts) as present
      from (select distinct ts from public.readings, now_s where plant_id = p_plant and ts >= now_s.t - 1800) r
  ),
  gk as (select ts, present from grid_known where present is not null),
  grid as (
    select (select count(*) = 3 and bool_and(not present) from (select present from gk order by ts desc limit 3) x) as down,
           (select count(*) = 2 and bool_and(present) from (select present from gk order by ts desc limit 2) x) as up,
           (select max(ts) from gk where present) as last_on,
           (select max(ts) from gk where not present) as last_off
  ),

  -- Battery temperature: the hottest inverter at the newest reading.
  hot as (
    select r.ts, r.batt_temp_c as temp from public.readings r, now_s
     where r.plant_id = p_plant and r.ts >= now_s.t - 600 and r.batt_temp_c > 0 and r.batt_temp_c < 80
     order by r.ts desc, r.batt_temp_c desc limit 1
  ),

  -- Charge spread between inverters' batteries, minute by minute, over the last hour.
  bank as (
    select r.ts, max(r.batt_soc) - min(r.batt_soc) as spread
      from public.readings r, now_s
     where r.plant_id = p_plant and r.ts >= now_s.t - 3600 and r.batt_soc between 1 and 100
     group by r.ts
    having count(distinct r.sn) >= 2
  ),
  drift as (select count(*) >= 30 and max(ts) - min(ts) >= 3300 and min(spread) >= 10 as drifting, max(ts) as ts from bank),

  -- Strings: 0057's dead_held, bounded to the window.
  str_latest as (select max(ts) as ts from public.strings, now_s where plant_id = p_plant and ts >= now_s.t - 900),
  dead_held as (
    select s.sn, s.no from public.strings s, loc, now_s
     where s.plant_id = p_plant and loc.hour between 11 and 14 and s.ts >= now_s.t - 900
       and coalesce(s.volt_v, 0) < 1.5 and coalesce(s.power_w, 0) < 5
       and exists (select 1 from public.strings o where o.plant_id = p_plant and o.ts = s.ts and o.sn = s.sn and o.no is distinct from s.no and coalesce(o.power_w, 0) > 200)
     group by s.sn, s.no
    having count(*) >= 12
       and exists (select 1 from public.strings cur, str_latest where cur.plant_id = p_plant and cur.ts = str_latest.ts and cur.sn = s.sn and cur.no = s.no and coalesce(cur.volt_v, 0) < 1.5 and coalesce(cur.power_w, 0) < 5)
  ),
  dead1 as (
    select d.sn, d.no, coalesce(nullif(m.alias, ''), 'Inverter ' || d.sn) as inverter
      from dead_held d left join plants.meta_info m on m.sn = d.sn
     order by m.ord nulls last, d.sn, d.no limit 1
  ),

  -- SunSynk's own clock: the newest device_time across the plant, read only from
  -- rows our polls wrote in the last 3 minutes. No such rows: our polls are failing,
  -- which is not the inverter going quiet, so no logger row at all.
  dev as (
    select max(extract(epoch from (r.device_time::timestamp at time zone (select tz from pz))))::bigint as last_dev
      from public.readings r, now_s
     where r.plant_id = p_plant and r.ts >= now_s.t - 180
       and r.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
  )

  select 'grid_down', 'grid_down:' || p_plant || ':' || x.since,
         jsonb_build_object('since', x.since, 'chargePct', x.soc)
    from (select (select min(ts) from gk where not present and ts > coalesce(grid.last_on, 0)) as since,
                 (select public.soc_at(p_plant, now_s.t) from now_s) as soc   -- R23: the one battery %
            from grid where grid.down) x, cfg
   where cfg.has_grid
  union all
  select 'grid_on', 'grid_on:' || p_plant,
         jsonb_build_object('since', (select min(ts) from gk where present and ts > coalesce(grid.last_off, 0)))
    from grid, cfg where grid.up and cfg.has_grid
  union all
  select 'batt_hot', 'batt_hot:' || p_plant || ':' || (select day from loc),
         jsonb_build_object('at', hot.ts, 'tempC', round(hot.temp)::int)
    from hot, cfg where hot.temp > 40 and cfg.has_battery
  union all
  select 'bank_drift', 'bank_drift:' || p_plant || ':' || (select day from loc),
         jsonb_build_object('banks', (
           select jsonb_agg(jsonb_build_object('name', coalesce(nullif(m.alias, ''), 'Inverter ' || r.sn), 'chargePct', round(r.batt_soc)::int)
                            order by m.ord nulls last, r.sn)
             from public.readings r left join plants.meta_info m on m.sn = r.sn
            where r.plant_id = p_plant and r.ts = drift.ts and r.batt_soc between 1 and 100))
    from drift, cfg where drift.drifting and cfg.has_battery and cfg.banks is distinct from 'shared'
  union all
  select 'string_dead', 'string_dead:' || p_plant || ':' || (select day from loc),
         jsonb_build_object('string', 'String ' || dead1.no, 'inverter', dead1.inverter,
           -- the minute after it last had voltage today; 15 min ago when it never did
           'since', coalesce((select max(s.ts) + 60 from public.strings s, day_lo
                               where s.plant_id = p_plant and s.sn = dead1.sn and s.no = dead1.no
                                 and s.ts >= day_lo.lo and coalesce(s.volt_v, 0) >= 1.5),
                             (select t - 900 from now_s)))
    from dead1
  union all
  select 'logger_stale', 'logger_stale:' || p_plant || ':' || dev.last_dev, jsonb_build_object('since', dev.last_dev)
    from dev, now_s where now_s.t - dev.last_dev > 900
  union all
  select 'logger_ok', 'logger_ok:' || p_plant, jsonb_build_object('at', dev.last_dev)
    from dev, now_s where now_s.t - dev.last_dev <= 900
$function$;
