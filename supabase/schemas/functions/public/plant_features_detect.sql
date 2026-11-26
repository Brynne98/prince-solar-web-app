CREATE OR REPLACE FUNCTION public.plant_features_detect(p_plant bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  cur record;
  hb boolean;
  hg boolean;
  n  bigint;
  v_floor bigint := extract(epoch from now())::bigint - 86400;
begin
  select has_battery, has_grid, features_source, features_checked_at into cur from public.plant_config where plant_id = p_plant;
  if cur.features_source = 'user' then
    return jsonb_build_object('plant', p_plant, 'skipped', 'user override');
  end if;
  -- battery and grid rarely change: once decided, a day between checks
  if cur.features_source = 'detected' and cur.features_checked_at > now() - interval '1 day' then
    return jsonb_build_object('plant', p_plant, 'skipped', 'checked today');
  end if;
  select count(*),
         bool_or((batt_soc between 1 and 100) or coalesce(batt_voltage_v, 0) > 10),
         bool_or(coalesce(grid_volt_v, 0) > 100 or coalesce(grid_import_today_kwh, 0) > 0
                 or coalesce(grid_export_today_kwh, 0) > 0 or abs(coalesce(grid_w, 0)) > 50)
    into n, hb, hg
    from public.readings
   where plant_id = p_plant and ts > v_floor and not carried;
  if n < 30 then
    return jsonb_build_object('plant', p_plant, 'decided', false, 'rows', n);
  end if;
  update public.plant_config
     set has_battery = hb, has_grid = hg, features_source = 'detected', features_updated_at = now()
   where plant_id = p_plant
     and (has_battery is distinct from hb or has_grid is distinct from hg or features_source = 'default');
  update public.plant_config set features_checked_at = now() where plant_id = p_plant;
  return jsonb_build_object('plant', p_plant, 'decided', true, 'hasBattery', hb, 'hasGrid', hg, 'rows', n);
end $function$;
