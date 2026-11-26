CREATE OR REPLACE FUNCTION billing.unknown_command(p_cmd text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  raise exception 'unknown billing_jobs command %', p_cmd using errcode = '22023';
end $function$;
