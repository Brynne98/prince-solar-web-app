CREATE OR REPLACE FUNCTION billing.new_reference()
 RETURNS text
 LANGUAGE sql
AS $function$ select 'psh_' || replace(gen_random_uuid()::text, '-', '') $function$;
