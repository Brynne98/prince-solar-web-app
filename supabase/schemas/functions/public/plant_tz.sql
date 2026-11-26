CREATE OR REPLACE FUNCTION public.plant_tz(p_plant bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$ select plants.tz(p_plant) $function$;
