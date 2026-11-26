CREATE OR REPLACE FUNCTION public.calibration_plant()
 RETURNS bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select public.cfg('CALIBRATION_PLANT')::bigint $function$;
