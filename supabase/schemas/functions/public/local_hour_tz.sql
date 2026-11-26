CREATE OR REPLACE FUNCTION public.local_hour_tz(ts bigint, tz text)
 RETURNS integer
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$ select extract(hour from (to_timestamp(ts) at time zone tz))::int $function$;
