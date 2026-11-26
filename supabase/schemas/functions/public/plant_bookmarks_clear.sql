CREATE OR REPLACE FUNCTION public.plant_bookmarks_clear(p_plants bigint[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update public.plant_config set backfill_next = null, backfill_until = null, temp_next = null
   where plant_id = any (coalesce(p_plants, '{}'))
$function$;
