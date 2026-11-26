CREATE OR REPLACE FUNCTION public.grid_live(p_volts double precision)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ select p_volts > 100 $function$;
