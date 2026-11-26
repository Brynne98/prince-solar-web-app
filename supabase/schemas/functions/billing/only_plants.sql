CREATE OR REPLACE FUNCTION billing.only_plants(p_rows jsonb, p_plants bigint[])
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) e
   where (e->>'plant_id')::bigint = any (p_plants)
$function$;
