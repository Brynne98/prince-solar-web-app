CREATE OR REPLACE FUNCTION plants.purge(p_plant bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n int; out jsonb := '{}';
begin
  delete from public.plant_config   where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from public.config_changes where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('config_changes', n);
  delete from private.meta          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  return out;
end $function$;
