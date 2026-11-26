CREATE OR REPLACE FUNCTION public.local_hour(ts bigint)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$ select extract(hour from (to_timestamp(ts) at time zone 'Africa/Johannesburg'))::int $function$;
