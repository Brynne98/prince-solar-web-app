-- ============================================================================
-- 0266 — the nightly minute rollup works in short slices (SOLAR-651).
--
-- Before: private.rollup_old_days rolled a whole day of minute rows for every plant
-- into 5-minute rows in one statement, then dropped the day. Measured 24 Nov 2026 on
-- a full day (22 plants, 117k rows): ~0.17 s a plant-day to read cold, ~0.35 s with
-- the insert. The 120 s statement_timeout covers the whole CALL (a COMMIT inside does
-- not reset it), so at ~350 plants the job would fail and no old day would be dropped.
--
-- Now:
--   1. private.rollup_progress keeps one row per raw day partition past the line:
--      the next start time, the slice width, counts, plants to redo. A partition is
--      known by its oid as well as its name and bounds.
--   2. A slice is a whole number of 5-minute buckets of one partition, sized for
--      ~25k raw rows (~2-3 s cold), and commits with its progress. A run stops
--      starting slices after 60 s; the next run carries on. A slice that died
--      (timeout, cancel, kill) halves the width for the rest of that partition.
--   3. Advisory key (8, 651): slices, redos and the drop take it exclusive with a
--      try-lock and never wait for it; a history delete (plant_readings_delete)
--      waits for it shared (at most one slice); the battery sign check
--      (batt_sign_detect) try-locks it shared first and skips if busy. Nobody waits
--      for the key while holding a lock on public.readings or public.strings, and
--      the drop takes every lock with NOWAIT, so no cycle and no queue behind it.
--   4. A battery sign flip marks the readings partitions already started; each
--      marked plant is rolled up again from its flipped raw rows before the drop.
--      5-minute rows of days dropped before a flip keep the old sign, as before.
--   5. The drop happens only once every slice and redo is done. If the locks are
--      busy it backs off (10 tries, 200 ms apart) and the next run tries again.
--   6. Two alarms fail the run, so the cron failure check alerts with nobody watching:
--      a day registered over 24 h ago and still not dropped (the nights fall behind,
--      or a drop never gets its locks), and a 300 s slice that held the key over 2 s
--      in the last 24 h (private.rollup_slow; plants are near the limit below;
--      SOLAR-659 is the follow-up).
--   7. Cron: every 5 minutes 05:00-07:55 UTC (was once at 04:30).
--
-- Limit: the smallest slice is 300 s of every plant, ~1.2 ms a plant cold (0.35 s a
-- plant-day / 288): over 2 s from ~1,700 plants. A history delete from the app waits for
-- it inside an 8 s request that also does the delete itself, so "remove plant" may fail
-- from ~3,500 plants, or sooner for a plant with years of history (SOLAR-659).
-- A night (36 runs of 60 s) rolls ~6,000 cold plant-days; the rest carries over.
-- Bulk test, local, 2,000 plants (3.3M minute rows, 6.6M string rows): matches the
-- one-shot rollup row for row, including stopped, killed and cancelled runs.
-- No monthly partitions remain (checked 24 Nov 2026); one found is skipped with a
-- notice. split_partition stays, unused.
-- ============================================================================

-- ── 1. progress ────────────────────────────────────────────────────────────
create table if not exists private.rollup_progress (
  part_oid       oid primary key,
  part_name      text not null,
  parent         text not null check (parent in ('readings', 'strings')),
  lo             bigint not null,
  hi             bigint not null,
  next_ts        bigint not null,
  width          integer not null check (width >= 300 and width % 300 = 0),
  redo           bigint[] not null default '{}',
  attempt_width  integer,
  attempt_pid    integer,
  attempt_qstart timestamptz,
  rows_in        bigint not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
revoke all on table private.rollup_progress from public, anon, authenticated;

-- 300 s slices that held the key too long (SOLAR-659's early warning)
create table if not exists private.rollup_slow (
  at        timestamptz not null default now(),
  part_name text not null,
  ms        integer not null
);
revoke all on table private.rollup_slow from public, anon, authenticated;

-- ── 2. rollup of a time range, optionally one plant ─────────────────────────
drop function if exists private.rollup_partition(text, text);
create or replace function private.rollup_partition(p_parent text, p_child text,
  p_from bigint default null, p_to bigint default null, p_plant bigint default null)
returns bigint
language plpgsql
set search_path = public, pg_temp
as $$
declare n bigint; f text := '';
begin
  if (p_from is null) <> (p_to is null) then
    raise exception 'rollup_partition: give both p_from and p_to, or neither';
  end if;
  if p_from is not null then
    -- a slice never cuts a 5-minute bucket: on conflict do nothing would keep half of it
    if p_from % 300 <> 0 or p_to % 300 <> 0 then
      raise exception 'rollup_partition: % to % is not on 5-minute bounds', p_from, p_to;
    end if;
    f := format(' and ts >= %s and ts < %s', p_from, p_to);
  end if;
  if p_plant is not null then
    f := f || format(' and plant_id = %s', p_plant);
  end if;
  if p_parent = 'readings' then
    execute format($q$
      insert into public.readings_5m (plant_id, sn, ts, n, n_fresh, n_carried, status_last, status_kinds, relay_last, relay_open_min, grid_off_min, pv_w_avg, pv_w_min, pv_w_max, batt_w_avg, batt_w_min, batt_w_max, batt_power_w_avg, batt_power_w_min, batt_power_w_max, grid_w_avg, grid_w_min, grid_w_max, load_w_avg, load_w_min, load_w_max, output_w_avg, output_w_min, output_w_max, batt2_power_w_avg, batt2_power_w_min, batt2_power_w_max, batt_current_a_avg, batt_current_a_min, batt_current_a_max, batt2_current_a_avg, batt2_current_a_min, batt2_current_a_max, batt_voltage_v_avg, batt_voltage_v_min, batt_voltage_v_max, batt2_voltage_v_avg, batt2_voltage_v_min, batt2_voltage_v_max, grid_volt_v_avg, grid_volt_v_min, grid_volt_v_max, grid_volt_l2_v_avg, grid_volt_l2_v_min, grid_volt_l2_v_max, grid_volt_l3_v_avg, grid_volt_l3_v_min, grid_volt_l3_v_max, output_volt_v_avg, output_volt_v_min, output_volt_v_max, output_volt_l2_v_avg, output_volt_l2_v_min, output_volt_l2_v_max, output_volt_l3_v_avg, output_volt_l3_v_min, output_volt_l3_v_max, batt_soc_avg, batt_soc_min, batt_soc_max, batt2_soc_avg, batt2_soc_min, batt2_soc_max, batt_temp_c_avg, batt_temp_c_min, batt_temp_c_max, batt2_temp_c_avg, batt2_temp_c_min, batt2_temp_c_max, grid_freq_hz_min, grid_freq_hz_max, load_freq_hz_min, load_freq_hz_max, output_freq_hz_min, output_freq_hz_max, grid_pf_avg, grid_in_w_avg, grid_out_w_avg, batt_pos_w_avg, batt_neg_w_avg, pv_today_kwh, pv_total_kwh, batt_chg_today_kwh, batt_dischg_today_kwh, batt_chg_total_kwh, batt_dischg_total_kwh, grid_import_today_kwh, grid_export_today_kwh, grid_import_total_kwh, grid_export_total_kwh, load_today_kwh, load_total_kwh)
      select plant_id, sn, (ts / 300) * 300,
           count(*),
           count(*) filter (where device_time is not null and not coalesce(carried, false)),
           count(*) filter (where carried),
           (array_agg(status order by ts desc))[1],
           count(distinct status),
           (array_agg(grid_relay_status order by ts desc))[1],
           count(*) filter (where grid_relay_status = '0'),
           count(*) filter (where device_time is not null and grid_volt_v is not null and grid_volt_v <= 100),
           avg(pv_w),
           min(pv_w),
           max(pv_w),
           avg(batt_w),
           min(batt_w),
           max(batt_w),
           avg(batt_power_w),
           min(batt_power_w),
           max(batt_power_w),
           avg(grid_w),
           min(grid_w),
           max(grid_w),
           avg(load_w),
           min(load_w),
           max(load_w),
           avg(output_w),
           min(output_w),
           max(output_w),
           avg(batt2_power_w),
           min(batt2_power_w),
           max(batt2_power_w),
           avg(batt_current_a),
           min(batt_current_a),
           max(batt_current_a),
           avg(batt2_current_a),
           min(batt2_current_a),
           max(batt2_current_a),
           avg(batt_voltage_v),
           min(batt_voltage_v),
           max(batt_voltage_v),
           avg(batt2_voltage_v),
           min(batt2_voltage_v),
           max(batt2_voltage_v),
           avg(grid_volt_v),
           min(grid_volt_v),
           max(grid_volt_v),
           avg(grid_volt_l2_v),
           min(grid_volt_l2_v),
           max(grid_volt_l2_v),
           avg(grid_volt_l3_v),
           min(grid_volt_l3_v),
           max(grid_volt_l3_v),
           avg(output_volt_v),
           min(output_volt_v),
           max(output_volt_v),
           avg(output_volt_l2_v),
           min(output_volt_l2_v),
           max(output_volt_l2_v),
           avg(output_volt_l3_v),
           min(output_volt_l3_v),
           max(output_volt_l3_v),
           avg(nullif(batt_soc, 0)),
           min(nullif(batt_soc, 0)),
           max(nullif(batt_soc, 0)),
           avg(nullif(batt2_soc, 0)),
           min(nullif(batt2_soc, 0)),
           max(nullif(batt2_soc, 0)),
           avg(case when batt_temp_c < -50 then null else batt_temp_c end),
           min(case when batt_temp_c < -50 then null else batt_temp_c end),
           max(case when batt_temp_c < -50 then null else batt_temp_c end),
           avg(case when batt2_temp_c < -50 then null else batt2_temp_c end),
           min(case when batt2_temp_c < -50 then null else batt2_temp_c end),
           max(case when batt2_temp_c < -50 then null else batt2_temp_c end),
           min(grid_freq_hz),
           max(grid_freq_hz),
           min(load_freq_hz),
           max(load_freq_hz),
           min(output_freq_hz),
           max(output_freq_hz),
           avg(grid_pf),
           avg(greatest(grid_w, 0)),
           avg(greatest(-grid_w, 0)),
           avg(greatest(batt_w, 0)),
           avg(greatest(-batt_w, 0)),
           (array_agg(pv_today_kwh order by ts desc) filter (where pv_today_kwh is not null))[1],
           (array_agg(pv_total_kwh order by ts desc) filter (where pv_total_kwh <> 0))[1],
           (array_agg(batt_chg_today_kwh order by ts desc) filter (where batt_chg_today_kwh is not null))[1],
           (array_agg(batt_dischg_today_kwh order by ts desc) filter (where batt_dischg_today_kwh is not null))[1],
           (array_agg(batt_chg_total_kwh order by ts desc) filter (where batt_chg_total_kwh <> 0))[1],
           (array_agg(batt_dischg_total_kwh order by ts desc) filter (where batt_dischg_total_kwh <> 0))[1],
           (array_agg(grid_import_today_kwh order by ts desc) filter (where grid_import_today_kwh is not null))[1],
           (array_agg(grid_export_today_kwh order by ts desc) filter (where grid_export_today_kwh is not null))[1],
           (array_agg(grid_import_total_kwh order by ts desc) filter (where grid_import_total_kwh <> 0))[1],
           (array_agg(grid_export_total_kwh order by ts desc) filter (where grid_export_total_kwh <> 0))[1],
           (array_agg(load_today_kwh order by ts desc) filter (where load_today_kwh is not null))[1],
           (array_agg(load_total_kwh order by ts desc) filter (where load_total_kwh <> 0))[1]
        from public.%I
       where plant_id is not null%s
       group by plant_id, sn, (ts / 300) * 300
      on conflict do nothing$q$, p_child, f);
  elsif p_parent = 'strings' then
    execute format($q$
      insert into public.strings_5m (plant_id, sn, no, ts, n, volt_v_avg, volt_v_min, volt_v_max, current_a_avg, current_a_min, current_a_max, power_w_avg, power_w_min, power_w_max, today_kwh)
      select plant_id, sn, no, (ts / 300) * 300,
           count(*),
           avg(volt_v),
           min(volt_v),
           max(volt_v),
           avg(current_a),
           min(current_a),
           max(current_a),
           avg(power_w),
           min(power_w),
           max(power_w),
           (array_agg(today_kwh order by ts desc) filter (where today_kwh <> 0))[1]
        from public.%I
       where plant_id is not null%s
       group by plant_id, sn, no, (ts / 300) * 300
      on conflict do nothing$q$, p_child, f);
  else
    raise exception 'rollup_partition: unknown parent %', p_parent;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function private.rollup_partition(text, text, bigint, bigint, bigint) from public, anon, authenticated;

-- ── 3. history delete waits for a running slice ─────────────────────────────
create or replace function private.plant_readings_delete(p_plant bigint)
returns jsonb
language plpgsql
set search_path to 'public', 'private', 'pg_temp'
as $function$
declare
  out jsonb := '{}'::jsonb;
  n bigint;
begin
  -- waits for a running rollup slice (SOLAR-651), so the slice cannot write back what this deletes
  perform pg_advisory_xact_lock_shared(8, 651);
  delete from public.readings            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings', n);
  delete from public.strings             where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings', n);
  delete from public.readings_5m         where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings_5m', n);
  delete from public.strings_5m          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings_5m', n);
  delete from public.agg_minute          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_minute', n);
  delete from public.agg_5m              where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_5m', n);
  delete from public.plant_energy        where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_energy', n);
  delete from public.inverter_history    where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history', n);
  delete from public.inverter_history_5m where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history_5m', n);
  delete from public.grid_off            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('grid_off', n);
  delete from private.gaps               where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('gaps', n);
  delete from private.grid_off_progress  where plant_id = p_plant;
  return out;
end $function$;

-- ── 4. battery sign check: skips while the rollup works, marks what to redo ─
create or replace function public.batt_sign_detect(p_plant bigint, p_default text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  cur      record;
  votes_c  int;
  votes_d  int;
  detected text;
  used     text;
  since    bigint;
  n_read   int := 0;
  n_agg    int := 0;
begin
  -- the nightly rollup is working: decide on a later poll (SOLAR-651). First, before
  -- the vote reads readings, so this never waits for the key holding a table lock.
  if not pg_try_advisory_xact_lock_shared(8, 651) then
    return jsonb_build_object('plant', p_plant, 'skipped', 'rollup busy');
  end if;
  select batt_positive_means, batt_sign_source, batt_sign_updated_at into cur
    from public.plant_config where plant_id = p_plant;
  if cur.batt_sign_source = 'user' then
    return jsonb_build_object('plant', p_plant, 'skipped', 'user override');
  end if;

  -- Half an hour apart, same inverter, real (not carried) rows, battery working
  -- hard enough that SoC must move a whole percent, and power keeping one sign
  -- for the whole window. (A 26 kWh pack at 900 W moves ~0.6 %/10 min, which an
  -- integer SoC cannot show; 30 min is the shortest window that always can.)
  with r as (
    select sn, ts, batt_soc, batt_power_w,
           lag(batt_soc, 30) over w as soc0,
           lag(ts, 30)       over w as ts0,
           min(sign(batt_power_w)) over (partition by sn order by ts rows between 30 preceding and current row) as smin,
           max(sign(batt_power_w)) over (partition by sn order by ts rows between 30 preceding and current row) as smax
      from public.readings
     where plant_id = p_plant
       and ts > extract(epoch from now())::bigint - 86400
       and not carried
       and batt_soc between 1 and 100
       and batt_power_w is not null
    window w as (partition by sn order by ts)
  ),
  v as (
    select case when batt_power_w > 0 and batt_soc > soc0 then 'charging'
                when batt_power_w < 0 and batt_soc < soc0 then 'charging'
                when batt_power_w > 0 and batt_soc < soc0 then 'discharging'
                when batt_power_w < 0 and batt_soc > soc0 then 'discharging' end as vote
      from r
     where ts0 is not null and ts - ts0 between 1700 and 2100
       and abs(batt_power_w) >= 200 and smin = smax
       and abs(batt_soc - soc0) >= 1
  )
  select count(*) filter (where vote = 'charging'), count(*) filter (where vote = 'discharging')
    into votes_c, votes_d from v where vote is not null;

  if votes_c + votes_d < 6 then
    return jsonb_build_object('plant', p_plant, 'votes', jsonb_build_object('charging', votes_c, 'discharging', votes_d), 'decided', false);
  end if;
  if votes_c >= 9 * votes_d then detected := 'charging';
  elsif votes_d >= 9 * votes_c then detected := 'discharging';
  else
    return jsonb_build_object('plant', p_plant, 'votes', jsonb_build_object('charging', votes_c, 'discharging', votes_d), 'decided', false, 'reason', 'split');
  end if;

  -- What the poller has been assuming for rows since the last decision.
  used := coalesce(cur.batt_positive_means, p_default);
  since := coalesce(extract(epoch from cur.batt_sign_updated_at)::bigint, 0);

  if detected is distinct from used then
    update public.readings set batt_w = -batt_w
     where plant_id = p_plant and ts >= since and batt_w is not null;
    get diagnostics n_read = row_count;
    -- raw days the rollup already started hold 5-minute rows of the old sign: redo this plant
    update private.rollup_progress
       set redo = array(select distinct unnest(redo || p_plant))
     where parent = 'readings' and next_ts > lo and since < hi;
    update public.agg_minute set batt_w = -batt_w
     where plant_id = p_plant and ts >= since and source in ('poller', 'poller_partial') and batt_w is not null;
    get diagnostics n_agg = row_count;
  end if;

  update public.plant_config
     set batt_positive_means = detected, batt_sign_source = 'detected', batt_sign_updated_at = now()
   where plant_id = p_plant;

  return jsonb_build_object('plant', p_plant, 'detected', detected, 'was', used,
                            'votes', jsonb_build_object('charging', votes_c, 'discharging', votes_d),
                            'flipped', jsonb_build_object('readings', n_read, 'agg', n_agg), 'decided', true);
end $$;

-- ── 5. the nightly job ──────────────────────────────────────────────────────
-- The rollup key, exclusive, for this transaction. A sign check or history delete holds
-- it shared for a moment, so try a few times before giving the run up.
create or replace function private.rollup_try_key()
returns boolean
language plpgsql
set search_path = pg_temp
as $$
begin
  for i in 1..5 loop
    if pg_try_advisory_xact_lock(8, 651) then return true; end if;
    perform pg_sleep(0.1);
  end loop;
  return false;
end $$;
revoke all on function private.rollup_try_key() from public, anon, authenticated;

-- The partition a progress row was made for is still there under that name, with
-- those bounds (a day partition dropped and made again gets a new oid).
create or replace function private.rollup_part_ok(p_oid oid, p_name text, p_parent text, p_lo bigint, p_hi bigint)
returns boolean
language sql stable
set search_path = pg_temp
as $$
  select coalesce(to_regclass(format('public.%I', p_name)) = p_oid, false)
     and exists (select 1 from pg_inherits i join pg_class ch on ch.oid = i.inhrelid
                  where ch.oid = p_oid and i.inhparent = format('public.%I', p_parent)::regclass
                    and private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'FROM') = p_lo
                    and private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'TO')   = p_hi)
$$;
revoke all on function private.rollup_part_ok(oid, text, text, bigint, bigint) from public, anon, authenticated;

drop procedure if exists private.rollup_old_days(integer);
create procedure private.rollup_old_days(p_days integer default 31,
  p_cap interval default interval '60 seconds', p_target_rows integer default 25000,
  p_slow interval default interval '2 seconds')
language plpgsql
as $$
declare
  cutoff  bigint := extract(epoch from ((now() at time zone 'UTC')::date - p_days)::timestamp at time zone 'UTC')::bigint;
  started timestamptz := clock_timestamp();
  my_pid  integer := pg_backend_pid();
  my_qs   timestamptz;
  skip    oid[] := '{}';
  c record; pr record;
  est double precision; w integer; t_to bigint; n_in bigint; n_out bigint;
  p bigint; live boolean; got boolean;
  t_key timestamptz; slow_ms integer := 0; slow_part text; busy boolean; have boolean;
begin
  if p_days is null or p_days < 1 then
    raise exception 'rollup_old_days: p_days must be 1 or more, got %', p_days;
  end if;
  select query_start into my_qs from pg_stat_activity where pid = my_pid;

  -- register partitions past the line; forget rows whose partition is gone or changed
  -- a partition replaced under the same name after part of it was rolled up: the new
  -- rows can't overwrite the buckets already written (on conflict do nothing), so stop
  -- and alert rather than drop the new raw rows. Clear by hand once checked.
  if exists (select 1 from private.rollup_progress g
              where g.next_ts > g.lo and to_regclass(format('public.%I', g.part_name)) is not null
                and not private.rollup_part_ok(g.part_oid, g.part_name, g.parent, g.lo, g.hi)) then
    raise exception 'rollup_old_days: % replaced after part of it was rolled up; check its 5-minute rows, then delete its rollup_progress row',
      (select string_agg(g.part_name, ', ') from private.rollup_progress g
        where g.next_ts > g.lo and to_regclass(format('public.%I', g.part_name)) is not null
          and not private.rollup_part_ok(g.part_oid, g.part_name, g.parent, g.lo, g.hi));
  end if;
  delete from private.rollup_progress g
   where not private.rollup_part_ok(g.part_oid, g.part_name, g.parent, g.lo, g.hi);
  for c in
    select p.relname as parent, ch.oid, ch.relname as name, ch.reltuples,
           private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'FROM') as lo,
           private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'TO')   as hi
      from pg_inherits i
      join pg_class ch on ch.oid = i.inhrelid
      join pg_class p  on p.oid  = i.inhparent
     where i.inhparent in ('public.readings'::regclass, 'public.strings'::regclass)
     order by 6, 1
  loop
    continue when c.hi > cutoff;
    -- a monthly, default or open-ended partition: not this job's
    if c.lo is null or c.hi is null or c.hi - c.lo <> 86400 or c.lo % 300 <> 0 then
      raise notice 'rollup_old_days: % is not a day partition, skipped', c.name;
      continue;
    end if;
    continue when exists (select 1 from private.rollup_progress where part_oid = c.oid);
    -- rows a day: the planner's count, or the size on disk when it has none yet
    -- (pg_relation_size locks the table, so only for one not registered yet)
    est := greatest(c.reltuples, pg_relation_size(c.oid) / case when c.parent = 'readings' then 200 else 80 end, 1);
    w := least(86400, greatest(300, floor(p_target_rows * 86400.0 / est / 300) * 300))::integer;
    insert into private.rollup_progress (part_oid, part_name, parent, lo, hi, next_ts, width)
    values (c.oid, c.name, c.parent, c.lo, c.hi, c.lo, w)
    on conflict (part_oid) do nothing;
  end loop;
  commit;

  <<work>>
  loop
    exit when clock_timestamp() - started > p_cap;
    select * into pr from private.rollup_progress
     where hi <= cutoff and part_oid <> all (skip) order by lo, parent limit 1;
    exit when not found;

    if pr.next_ts < pr.hi or cardinality(pr.redo) > 0 then
      -- ── a slice or a redo: the key, then the partition as registered ──
      if not private.rollup_try_key() then exit work; end if;
      select * into pr from private.rollup_progress where part_oid = pr.part_oid;
      if not found then commit; continue; end if;
      -- never wait for the table while holding the key: a history delete waits on the key
      busy := false;
      begin
        execute format('lock table public.%I in access share mode nowait', pr.part_name);
      exception
        when undefined_table then null;
        when lock_not_available then busy := true;
      end;
      if busy then commit; exit work; end if;
      if not private.rollup_part_ok(pr.part_oid, pr.part_name, pr.parent, pr.lo, pr.hi) then
        if pr.next_ts > pr.lo and to_regclass(format('public.%I', pr.part_name)) is not null then
          raise exception 'rollup_old_days: % replaced after part of it was rolled up; check its 5-minute rows, then delete its rollup_progress row',
            pr.part_name;
        end if;
        -- dropped, or replaced before any slice: forget it; a new one registers next run
        raise notice 'rollup_old_days: % changed since it was registered, progress dropped', pr.part_name;
        delete from private.rollup_progress where part_oid = pr.part_oid;
        commit;
        continue;
      end if;
      -- another run finished it meanwhile: let go of the key before the drop
      if pr.next_ts >= pr.hi and cardinality(pr.redo) = 0 then commit; continue; end if;
    end if;

    if pr.next_ts < pr.hi then
      -- ── a slice: mark it, then do it ──
      w := pr.width;
      if pr.attempt_pid is not null then
        perform pg_stat_clear_snapshot();
        select exists (select 1 from pg_stat_activity
                        where pid = pr.attempt_pid and pid <> my_pid
                          and state = 'active' and query_start = pr.attempt_qstart) into live;
        if live then commit; exit work; end if;
        -- the last slice died: half as wide for the rest of this partition
        w := greatest(300, (pr.attempt_width / 2 / 300) * 300);
        raise notice 'rollup_old_days: % slice of % s died, now % s', pr.part_name, pr.attempt_width, w;
      end if;
      update private.rollup_progress
         set width = w, attempt_width = w, attempt_pid = my_pid, attempt_qstart = my_qs, updated_at = now()
       where part_oid = pr.part_oid;
      commit;

      if not private.rollup_try_key() then
        -- a history delete or the sign check came in between: undo our mark, try later
        update private.rollup_progress set attempt_width = null, attempt_pid = null, attempt_qstart = null
         where part_oid = pr.part_oid and attempt_pid = my_pid and attempt_qstart = my_qs;
        commit;
        exit work;
      end if;
      t_key := clock_timestamp();
      select * into pr from private.rollup_progress where part_oid = pr.part_oid;
      if not found or pr.attempt_pid is distinct from my_pid or pr.attempt_qstart is distinct from my_qs then
        commit; continue;
      end if;
      -- never wait for the table while holding the key: a history delete waits on the key
      busy := false;
      begin
        execute format('lock table public.%I in access share mode nowait', pr.part_name);
      exception
        when undefined_table then null;
        when lock_not_available then busy := true;
      end;
      if busy then
        update private.rollup_progress set attempt_width = null, attempt_pid = null, attempt_qstart = null
         where part_oid = pr.part_oid and attempt_pid = my_pid and attempt_qstart = my_qs;
        commit;
        exit work;
      end if;
      if not private.rollup_part_ok(pr.part_oid, pr.part_name, pr.parent, pr.lo, pr.hi) then
        commit; continue;   -- the check at the top of the next turn forgets it
      end if;
      t_to := least(pr.next_ts + pr.width, pr.hi);
      execute format('select count(*) from public.%I where ts >= %s and ts < %s', pr.part_name, pr.next_ts, t_to)
        into n_in;
      perform private.rollup_partition(pr.parent, pr.part_name, pr.next_ts, t_to);
      update private.rollup_progress
         set next_ts = t_to, rows_in = rows_in + n_in,
             attempt_width = null, attempt_pid = null, attempt_qstart = null, updated_at = now()
       where part_oid = pr.part_oid;
      commit;
      if clock_timestamp() - t_key > p_slow and pr.width > 300 then
        -- held the key too long: narrower from the next slice on
        update private.rollup_progress set width = greatest(300, (width / 2 / 300) * 300)
         where part_oid = pr.part_oid;
        commit;
      elsif pr.width = 300 and extract(epoch from clock_timestamp() - t_key) * 1000 > slow_ms then
        -- the slowest slice that can't get narrower: the early warning for SOLAR-659
        slow_ms := (extract(epoch from clock_timestamp() - t_key) * 1000)::integer;
        slow_part := pr.part_name;
      end if;

    elsif cardinality(pr.redo) > 0 then
      -- ── one plant again, from raw rows its sign check flipped (readings only) ──
      p := pr.redo[1];
      if pr.parent = 'readings' then
        delete from public.readings_5m where plant_id = p and ts >= pr.lo and ts < pr.hi;
        n_out := private.rollup_partition(pr.parent, pr.part_name, pr.lo, pr.hi, p);
        raise notice 'rollup_old_days: % redone for plant %, % buckets', pr.part_name, p, n_out;
      end if;
      update private.rollup_progress set redo = array_remove(redo, p), updated_at = now()
       where part_oid = pr.part_oid;
      commit;

    else
      -- ── the drop: every lock without waiting, a few tries ──
      got := false;
      for i in 1..10 loop
        begin
          execute format('lock table only public.%I in access exclusive mode nowait', pr.parent);
          if not pg_try_advisory_xact_lock(8, 651) then
            raise exception 'rollup key busy' using errcode = 'lock_not_available';
          end if;
          select * into pr from private.rollup_progress where part_oid = pr.part_oid;
          have := found;
          if have then
            -- the child too, before reading its bounds (that locks it), all without waiting
            begin
              execute format('lock table public.%I in access exclusive mode nowait', pr.part_name);
            exception when undefined_table then
              null;
            end;
          end if;
          if not have then
            null;   -- another run dropped it
          elsif not private.rollup_part_ok(pr.part_oid, pr.part_name, pr.parent, pr.lo, pr.hi) then
            if to_regclass(format('public.%I', pr.part_name)) is not null then
              raise exception 'rollup_old_days: % replaced after part of it was rolled up; check its 5-minute rows, then delete its rollup_progress row',
                pr.part_name;
            end if;
            delete from private.rollup_progress where part_oid = pr.part_oid;
          elsif pr.next_ts >= pr.hi and cardinality(pr.redo) = 0 then
            execute format('drop table public.%I', pr.part_name);
            insert into private.partitions_dropped (partition_name, upper_bound, rows_dropped)
            values (pr.part_name, to_timestamp(pr.hi), pr.rows_in)
            on conflict (partition_name) do update
              set dropped_at = now(), upper_bound = excluded.upper_bound, rows_dropped = excluded.rows_dropped;
            delete from private.rollup_progress where part_oid = pr.part_oid;
          end if;
          got := true;
        exception when lock_not_available then
          got := false;
        end;
        if got then commit; exit; end if;
        rollback;
        perform pg_sleep(0.2);
      end loop;
      if not got then
        raise notice 'rollup_old_days: % busy, drop left for the next run', pr.part_name;
        skip := skip || pr.part_oid;
      end if;
    end if;
  end loop;

  -- the slow-slice alarm stays up for 24 h, so the cron check can't miss a one-off
  if slow_ms > extract(epoch from p_slow) * 1000 then
    insert into private.rollup_slow (part_name, ms) values (slow_part, slow_ms);
  end if;
  delete from private.rollup_slow where at < now() - interval '30 days';
  commit;

  if exists (select 1 from private.rollup_progress where created_at < now() - interval '24 hours') then
    raise exception 'rollup_old_days: % waiting over 24 h, not yet rolled up and dropped',
      (select string_agg(part_name, ', ' order by lo, parent) from private.rollup_progress
        where created_at < now() - interval '24 hours');
  end if;
  select part_name, ms into slow_part, slow_ms from private.rollup_slow
   where at > now() - interval '24 hours' order by ms desc limit 1;
  if found then
    raise exception 'rollup_old_days: a 300 s slice of % held the rollup key % ms in the last 24 h; plants are near the limit, see SOLAR-659',
      slow_part, slow_ms;
  end if;
end $$;
revoke all on procedure private.rollup_old_days(integer, interval, integer, interval) from public, anon, authenticated;

-- ── 6. cron ─────────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping jobs (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'rollup-old-days') then
    perform cron.unschedule('rollup-old-days');
  end if;
  perform cron.schedule('rollup-old-days', '*/5 5-7 * * *', 'call private.rollup_old_days(31)');
end $$;
