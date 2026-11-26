CREATE OR REPLACE FUNCTION public.inverters_cached(p_account uuid)
 RETURNS TABLE(sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text, gsn text, comm_type text, plant_name text, ord integer, status integer, last_reading jsonb, carried_run integer, upload_s integer)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  select c.sn, c.plant_id, c.alias, c.model, c.soft_ver, c.hmi_ver, c.gsn, c.comm_type, c.plant_name, c.ord, c.status,
         c.last_reading, c.carried_run, c.upload_s
    from public.inverters_cached_many(array[p_account]) c
$function$;
