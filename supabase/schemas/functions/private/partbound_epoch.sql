CREATE OR REPLACE FUNCTION private.partbound_epoch(p_bound text, p_which text)
 RETURNS bigint
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_temp'
AS $function$
  select nullif(regexp_replace(split_part(split_part(p_bound, p_which || ' (', 2), ')', 1), '\D', '', 'g'), '')::bigint
$function$;
