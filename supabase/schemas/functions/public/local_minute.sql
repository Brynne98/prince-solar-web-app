CREATE OR REPLACE FUNCTION public.local_minute(ts bigint)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$ select extract(minute from (to_timestamp(ts) at time zone 'Africa/Johannesburg'))::int $function$;
