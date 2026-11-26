CREATE OR REPLACE FUNCTION private.plants_tombstone(p_plants bigint[])
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  if billing.is_live() then return; end if;
  insert into private.plant_purge (plant_id)
  select distinct p from unnest(p_plants) p
  on conflict (plant_id) do nothing;
  delete from public.app_config
   where key = 'CALIBRATION_PLANT' and value = any (p_plants::double precision[]);
end $function$;
