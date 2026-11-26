CREATE OR REPLACE FUNCTION public.meta_upsert(p_rows jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  insert into private.meta (
    sn, updated_ts, alias, model, soft_ver, hmi_ver, gsn, comm_type,
    capacity_ah, number_of_batteries, plant_id, plant_name, ord, status)
  select
    r->>'sn',
    (r->>'updated_ts')::bigint,
    r->>'alias', r->>'model', r->>'soft_ver', r->>'hmi_ver', r->>'gsn', r->>'comm_type',
    nullif(r->>'capacity_ah', '')::double precision,
    nullif(r->>'number_of_batteries', '')::integer,
    nullif(r->>'plant_id', '')::bigint,
    r->>'plant_name',
    nullif(r->>'ord', '')::integer,
    nullif(r->>'status', '')::integer
  from jsonb_array_elements(p_rows) r
  on conflict (sn) do update set
    updated_ts = excluded.updated_ts, alias = excluded.alias, model = excluded.model,
    soft_ver = excluded.soft_ver, hmi_ver = excluded.hmi_ver, gsn = excluded.gsn,
    comm_type = excluded.comm_type, capacity_ah = excluded.capacity_ah,
    number_of_batteries = excluded.number_of_batteries,
    plant_id = excluded.plant_id, plant_name = excluded.plant_name,
    ord = coalesce(excluded.ord, private.meta.ord),
    status = coalesce(excluded.status, private.meta.status)
$function$;
