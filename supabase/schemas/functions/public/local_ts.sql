CREATE OR REPLACE FUNCTION public.local_ts(ts bigint)
 RETURNS timestamp without time zone
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$ select to_timestamp(ts) at time zone 'Africa/Johannesburg' $function$;
