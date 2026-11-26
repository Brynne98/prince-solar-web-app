CREATE OR REPLACE FUNCTION public.plant_config_batt_sign_guard()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if auth.uid() is not null and new.batt_positive_means is distinct from old.batt_positive_means then
    new.batt_sign_source := case when new.batt_positive_means is null then 'default' else 'user' end;
    new.batt_sign_updated_at := now();
  end if;
  return new;
end $function$;
