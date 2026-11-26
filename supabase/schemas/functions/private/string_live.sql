CREATE OR REPLACE FUNCTION private.string_live(v double precision, i double precision, p double precision, t double precision)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$ select coalesce(v, 0) <> 0 or coalesce(i, 0) <> 0 or coalesce(p, 0) <> 0 or coalesce(t, 0) <> 0 $function$;
