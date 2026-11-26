CREATE OR REPLACE FUNCTION plants.tz_valid(p text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
begin
  if p is null or btrim(p) = '' then return false; end if;
  perform timestamp '2000-01-01' at time zone p;
  return true;
exception when others then return false;
end $function$;
