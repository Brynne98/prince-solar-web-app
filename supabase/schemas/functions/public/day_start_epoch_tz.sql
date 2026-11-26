CREATE OR REPLACE FUNCTION public.day_start_epoch_tz(d date, tz text)
 RETURNS bigint
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$ select extract(epoch from (d::timestamp at time zone tz))::bigint $function$;
