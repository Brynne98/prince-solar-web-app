CREATE OR REPLACE FUNCTION public.plant_inverters(p_plant bigint)
 RETURNS TABLE(sn text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  select i.sn from private.inverters i where i.plant_id = p_plant order by i.sn
$function$;
