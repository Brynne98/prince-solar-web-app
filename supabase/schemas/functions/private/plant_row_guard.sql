CREATE OR REPLACE FUNCTION private.plant_row_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.plant_id is null then return new; end if;
  if current_setting('billing.guarded', true) = 'on' or tg_table_name in ('inverters', 'plant_config', 'meta')
     or coalesce((billing.plant_state(new.plant_id)->>'read_now')::boolean, false) then
    return new;
  end if;
  return null;
end $function$;
