CREATE OR REPLACE FUNCTION public.local_day(ts bigint)
 RETURNS date
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$ select (to_timestamp(ts) at time zone 'Africa/Johannesburg')::date $function$;
