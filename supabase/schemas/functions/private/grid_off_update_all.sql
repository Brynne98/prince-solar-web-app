CREATE OR REPLACE FUNCTION private.grid_off_update_all()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare p bigint; out jsonb := '{}'::jsonb;
begin
  for p in select distinct plant_id from plants.user_plants loop
    out := out || jsonb_build_object(p::text, private.grid_off_update(p));
  end loop;
  return out;
end $function$;
