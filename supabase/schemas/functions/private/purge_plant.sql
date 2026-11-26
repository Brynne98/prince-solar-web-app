CREATE OR REPLACE FUNCTION private.purge_plant(p_plant bigint, p_wait boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  out jsonb;
  n bigint;
begin
  if billing.is_live() then return null; end if;
  if p_wait then
    perform pg_advisory_xact_lock(p_plant);
  elsif not pg_try_advisory_xact_lock(p_plant) then
    return null;
  end if;
  if not exists (select 1 from private.plant_purge where plant_id = p_plant) then
    return null;
  end if;
  if exists (select 1 from plants.user_plants where plant_id = p_plant) then
    delete from private.plant_purge where plant_id = p_plant;
    return jsonb_build_object('skipped', 'linked again');
  end if;

  out := private.plant_readings_delete(p_plant);
  out := out || plants.purge(p_plant);   -- this part's rows: settings, their log, inverters, meta (R1, R2)
  delete from private.plant_alert_state    where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_alert_state', n);
  delete from private.inverter_alert_state where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_alert_state', n);
  delete from private.string_alert_state   where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('string_alert_state', n);
  delete from private.plant_wipe           where plant_id = p_plant;
  delete from private.plant_purge          where plant_id = p_plant;
  return out;
end $function$;
