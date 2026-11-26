CREATE OR REPLACE FUNCTION public.day_start_epoch(d date)
 RETURNS bigint
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$ select extract(epoch from (d::timestamp at time zone 'Africa/Johannesburg'))::bigint $function$;
