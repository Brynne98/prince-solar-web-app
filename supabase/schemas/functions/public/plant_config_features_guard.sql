CREATE OR REPLACE FUNCTION public.plant_config_features_guard()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if auth.uid() is not null and (new.has_battery is distinct from old.has_battery or new.has_grid is distinct from old.has_grid) then
    new.features_source := case when new.has_battery is null and new.has_grid is null then 'default' else 'user' end;
    new.features_updated_at := now();
  end if;
  return new;
end $function$;
