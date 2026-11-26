CREATE OR REPLACE FUNCTION private.rollup_try_key()
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'pg_temp'
AS $function$
begin
  for i in 1..5 loop
    if pg_try_advisory_xact_lock(8, 651) then return true; end if;
    perform pg_sleep(0.1);
  end loop;
  return false;
end $function$;
