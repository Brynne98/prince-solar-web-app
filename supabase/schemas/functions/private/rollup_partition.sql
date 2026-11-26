CREATE OR REPLACE FUNCTION private.rollup_partition(p_parent text, p_child text, p_from bigint DEFAULT NULL::bigint, p_to bigint DEFAULT NULL::bigint, p_plant bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
end $function$;
