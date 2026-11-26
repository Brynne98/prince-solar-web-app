CREATE OR REPLACE FUNCTION public.inverters_seed(p_rows jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  insert into private.inverters (sn, plant_id, account_id)
  select r->>'sn', nullif(r->>'plant_id', '')::bigint, nullif(r->>'account_id', '')::uuid
    from jsonb_array_elements(p_rows) r
  on conflict (sn) do update
    set plant_id = excluded.plant_id, account_id = excluded.account_id
$function$;
