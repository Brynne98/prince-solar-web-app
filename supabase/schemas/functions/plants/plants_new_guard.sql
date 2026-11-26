CREATE OR REPLACE FUNCTION plants.plants_new_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.legacy or new.id < 1000000000000 then
    raise exception 'plants: a new plant takes an id from plants.plant_id_seq (got %)', new.id;
  end if;
  return new;
end $function$;
