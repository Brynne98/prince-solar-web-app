CREATE OR REPLACE FUNCTION billing.has_history(p_plant bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select exists (select 1 from public.agg_minute where plant_id = p_plant)
      or exists (select 1 from public.agg_5m where plant_id = p_plant)
      or exists (select 1 from public.readings where plant_id = p_plant)
      or exists (select 1 from public.plant_energy where plant_id = p_plant)
      or exists (select 1 from public.inverter_history where plant_id = p_plant)
      or exists (select 1 from public.grid_off where plant_id = p_plant)
$function$;
