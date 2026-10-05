-- ============================================================================
-- 0070 — inverter and string readings: full detail, then 5-minute rows forever
-- (SOLAR-60).
--
-- Before: readings and strings partitions were dropped outright 90 days after
-- their month ended (0036). Per-inverter battery voltage and temperature,
-- grid voltage per phase and per-string output live only in these tables, so
-- everything a battery-wear, string-decline or outage feature would need was
-- gone after three months.
--
-- Now: once every day of a monthly partition is more than 60 days old (SunSynk
-- keeps its own copy about that long), the partition is summarised into
-- readings_5m / strings_5m and then dropped. Dropping whole months avoids
-- row-by-row deletes, so full detail lasts 60-91 days. Decided by Brynne,
-- 2026-10-05 (SOLAR-43 review, option A).
--
-- Each 5-minute row (rules from the SOLAR-60 build-rules comment):
--   * avg / min / max of every measured value, stored as real;
--   * n readings, n_fresh (dated, not carried) and n_carried, so energy is
--     avg x n x 60 s and a bucket with missing minutes is visible;
--   * grid import/export and battery +/- averaged apart, so opposite flows in
--     one bucket do not cancel;
--   * every *_today_kwh / *_total_kwh as its last non-zero value (the slave
--     reports 0 for counters it does not keep);
--   * SoC 0 and battery temperatures below -50 C are no reading (extract.ts);
--   * status and relay as their last value, plus how many distinct status
--     codes, minutes with the relay open, and minutes with dated grid voltage
--     at or under 100 V.
-- batt_w follows plant_config.batt_positive_means at the time of the rollup;
-- batt_power_w is the inverter's raw sign and is never flipped, so a later
-- batt_sign_detect() correction can be applied to old buckets from it.
--
-- Nothing reads these tables yet. Owners can read their own plant's rows.
-- ============================================================================

create table if not exists public.readings_5m (
  plant_id                bigint not null,
  sn                      text   not null,
  ts                      bigint not null,     -- bucket start, epoch seconds, multiple of 300
  n                       smallint,
  n_fresh                 smallint,
  n_carried               smallint,
  status_last             integer,
  status_kinds            smallint,
  relay_last              text,
  relay_open_min          smallint,
  grid_off_min            smallint,
  pv_w_avg                real,
  pv_w_min                real,
  pv_w_max                real,
  batt_w_avg              real,
  batt_w_min              real,
  batt_w_max              real,
  batt_power_w_avg        real,
  batt_power_w_min        real,
  batt_power_w_max        real,
  grid_w_avg              real,
  grid_w_min              real,
  grid_w_max              real,
  load_w_avg              real,
  load_w_min              real,
  load_w_max              real,
  output_w_avg            real,
  output_w_min            real,
  output_w_max            real,
  batt2_power_w_avg       real,
  batt2_power_w_min       real,
  batt2_power_w_max       real,
  batt_current_a_avg      real,
  batt_current_a_min      real,
  batt_current_a_max      real,
  batt2_current_a_avg     real,
  batt2_current_a_min     real,
  batt2_current_a_max     real,
  batt_voltage_v_avg      real,
  batt_voltage_v_min      real,
  batt_voltage_v_max      real,
  batt2_voltage_v_avg     real,
  batt2_voltage_v_min     real,
  batt2_voltage_v_max     real,
  grid_volt_v_avg         real,
  grid_volt_v_min         real,
  grid_volt_v_max         real,
  grid_volt_l2_v_avg      real,
  grid_volt_l2_v_min      real,
  grid_volt_l2_v_max      real,
  grid_volt_l3_v_avg      real,
  grid_volt_l3_v_min      real,
  grid_volt_l3_v_max      real,
  output_volt_v_avg       real,
  output_volt_v_min       real,
  output_volt_v_max       real,
  output_volt_l2_v_avg    real,
  output_volt_l2_v_min    real,
  output_volt_l2_v_max    real,
  output_volt_l3_v_avg    real,
  output_volt_l3_v_min    real,
  output_volt_l3_v_max    real,
  batt_soc_avg            real,
  batt_soc_min            real,
  batt_soc_max            real,
  batt2_soc_avg           real,
  batt2_soc_min           real,
  batt2_soc_max           real,
  batt_temp_c_avg         real,
  batt_temp_c_min         real,
  batt_temp_c_max         real,
  batt2_temp_c_avg        real,
  batt2_temp_c_min        real,
  batt2_temp_c_max        real,
  grid_freq_hz_min        real,
  grid_freq_hz_max        real,
  load_freq_hz_min        real,
  load_freq_hz_max        real,
  output_freq_hz_min      real,
  output_freq_hz_max      real,
  grid_pf_avg             real,
  grid_in_w_avg           real,
  grid_out_w_avg          real,
  batt_pos_w_avg          real,
  batt_neg_w_avg          real,
  pv_today_kwh            real,
  pv_total_kwh            real,
  batt_chg_today_kwh      real,
  batt_dischg_today_kwh   real,
  batt_chg_total_kwh      real,
  batt_dischg_total_kwh   real,
  grid_import_today_kwh   real,
  grid_export_today_kwh   real,
  grid_import_total_kwh   real,
  grid_export_total_kwh   real,
  load_today_kwh          real,
  load_total_kwh          real,
  primary key (plant_id, sn, ts)
);
comment on table public.readings_5m is
  'Per-inverter readings older than 60 days, one row per 5 minutes: avg/min/max of each value, counts, last counters. Written by private.rollup_old_partitions (SOLAR-60).';

create table if not exists public.strings_5m (
  plant_id                bigint  not null,
  sn                      text    not null,
  no                      integer not null,
  ts                      bigint  not null,
  n                       smallint,
  volt_v_avg              real,
  volt_v_min              real,
  volt_v_max              real,
  current_a_avg           real,
  current_a_min           real,
  current_a_max           real,
  power_w_avg             real,
  power_w_min             real,
  power_w_max             real,
  today_kwh               real,
  primary key (plant_id, sn, no, ts)
);
comment on table public.strings_5m is
  'Per-string readings older than 60 days, one row per 5 minutes: avg/min/max of V, A, W, count, last today_kwh. Written by private.rollup_old_partitions (SOLAR-60).';

do $$
declare t text;
begin
  foreach t in array array['readings_5m', 'strings_5m'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (plant_id in (select public.my_plant_ids()))',
      t || '_read', t);
  end loop;
end $$;

-- ── summarise one partition ─────────────────────────────────────────────────
create or replace function private.rollup_partition(p_parent text, p_child text)
returns bigint
language plpgsql
set search_path = public, pg_temp
as $$
declare n bigint;
begin
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
           (array_agg(pv_today_kwh order by ts desc) filter (where pv_today_kwh <> 0))[1],
           (array_agg(pv_total_kwh order by ts desc) filter (where pv_total_kwh <> 0))[1],
           (array_agg(batt_chg_today_kwh order by ts desc) filter (where batt_chg_today_kwh <> 0))[1],
           (array_agg(batt_dischg_today_kwh order by ts desc) filter (where batt_dischg_today_kwh <> 0))[1],
           (array_agg(batt_chg_total_kwh order by ts desc) filter (where batt_chg_total_kwh <> 0))[1],
           (array_agg(batt_dischg_total_kwh order by ts desc) filter (where batt_dischg_total_kwh <> 0))[1],
           (array_agg(grid_import_today_kwh order by ts desc) filter (where grid_import_today_kwh <> 0))[1],
           (array_agg(grid_export_today_kwh order by ts desc) filter (where grid_export_today_kwh <> 0))[1],
           (array_agg(grid_import_total_kwh order by ts desc) filter (where grid_import_total_kwh <> 0))[1],
           (array_agg(grid_export_total_kwh order by ts desc) filter (where grid_export_total_kwh <> 0))[1],
           (array_agg(load_today_kwh order by ts desc) filter (where load_today_kwh <> 0))[1],
           (array_agg(load_total_kwh order by ts desc) filter (where load_total_kwh <> 0))[1]
        from public.%I
       where plant_id is not null
       group by plant_id, sn, (ts / 300) * 300
      on conflict do nothing$q$, p_child);
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
       where plant_id is not null
       group by plant_id, sn, no, (ts / 300) * 300
      on conflict do nothing$q$, p_child);
  else
    raise exception 'rollup_partition: unknown parent %', p_parent;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

-- ── summarise, then drop, every month wholly older than p_days ──────────────
create or replace function private.rollup_old_partitions(p_days integer default 60)
returns jsonb
language plpgsql
set search_path = pg_temp
as $$
declare
  t text; c record;
  cutoff bigint := extract(epoch from now())::bigint - p_days * 86400;
  hi bigint; n bigint; made bigint; done jsonb := '[]'::jsonb;
begin
  foreach t in array array['readings', 'strings'] loop
    for c in
      select ch.relname as name, pg_get_expr(ch.relpartbound, ch.oid) as bound
        from pg_inherits i join pg_class ch on ch.oid = i.inhrelid
       where i.inhparent = ('public.' || t)::regclass
       order by ch.relname
    loop
      hi := private.partbound_epoch(c.bound, 'TO');
      if hi > cutoff then continue; end if;

      execute format('select count(*) from public.%I', c.name) into n;
      made := private.rollup_partition(t, c.name);
      execute format('drop table public.%I', c.name);
      insert into private.partitions_dropped (partition_name, upper_bound, rows_dropped)
      values (c.name, to_timestamp(hi), n)
      on conflict (partition_name) do update
        set dropped_at = now(), upper_bound = excluded.upper_bound, rows_dropped = excluded.rows_dropped;
      done := done || jsonb_build_object('partition', c.name, 'rows', n, 'buckets', made);
    end loop;
  end loop;
  return done;
end $$;

revoke all on function private.rollup_partition(text, text) from public, anon, authenticated;
revoke all on function private.rollup_old_partitions(integer) from public, anon, authenticated;

-- ── purge: 0069's body plus the two new tables ──────────────────────────────
create or replace function private.purge_plant(p_plant bigint, p_wait boolean default true)
returns jsonb
language plpgsql
set search_path = public, private, pg_temp
as $$
declare
  out jsonb := '{}'::jsonb;
  n bigint;
begin
  if p_wait then
    perform pg_advisory_xact_lock(p_plant);
  elsif not pg_try_advisory_xact_lock(p_plant) then
    return null;
  end if;
  if not exists (select 1 from private.plant_purge where plant_id = p_plant) then
    return null;
  end if;
  if exists (select 1 from public.plant_users where plant_id = p_plant) then
    delete from private.plant_purge where plant_id = p_plant;
    return jsonb_build_object('skipped', 'linked again');
  end if;

  delete from public.readings         where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings', n);
  delete from public.strings          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings', n);
  delete from public.readings_5m      where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings_5m', n);
  delete from public.strings_5m       where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings_5m', n);
  delete from public.agg_minute       where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_minute', n);
  delete from public.plant_energy     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_energy', n);
  delete from public.inverter_history where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history', n);
  delete from public.grid_off         where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('grid_off', n);
  delete from public.plant_config     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from private.gaps            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('gaps', n);
  delete from private.meta            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters       where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  delete from private.grid_off_progress where plant_id = p_plant;
  delete from private.plant_purge     where plant_id = p_plant;
  return out;
end $$;

-- ── schedule: replaces drop-old-partitions; daily 04:30 UTC, after grid-off ──
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping rollup job (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'drop-old-partitions') then
    perform cron.unschedule('drop-old-partitions');
  end if;
  if exists (select 1 from cron.job where jobname = 'rollup-old-partitions') then
    perform cron.unschedule('rollup-old-partitions');
  end if;
  perform cron.schedule('rollup-old-partitions', '30 4 * * *', 'select private.rollup_old_partitions(60)');
end $$;

drop function if exists private.drop_old_partitions(integer);

-- Summarise and drop what is already past the line (July 2026 on production).
do $$
begin
  raise notice 'rollup_old_partitions: %', private.rollup_old_partitions(60);
end $$;
