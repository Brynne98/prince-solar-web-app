CREATE OR REPLACE FUNCTION public.local_day_tz(ts bigint, tz text)
 RETURNS date
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$ select (to_timestamp(ts) at time zone tz)::date $function$;
