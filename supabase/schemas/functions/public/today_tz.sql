CREATE OR REPLACE FUNCTION public.today_tz(tz text)
 RETURNS date
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$ select (now() at time zone tz)::date $function$;
