CREATE OR REPLACE FUNCTION public.local_ts_tz(ts bigint, tz text)
 RETURNS timestamp without time zone
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$ select to_timestamp(ts) at time zone tz $function$;
