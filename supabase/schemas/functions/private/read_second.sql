CREATE OR REPLACE FUNCTION private.read_second(p_key text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_temp'
AS $function$
  select ('x' || '0' || left(md5(p_key), 7))::bit(32)::int % 60
$function$;
