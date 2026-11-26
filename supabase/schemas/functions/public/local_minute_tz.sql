CREATE OR REPLACE FUNCTION public.local_minute_tz(ts bigint, tz text)
 RETURNS integer
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$ select extract(minute from (to_timestamp(ts) at time zone tz))::int $function$;
