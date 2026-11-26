CREATE OR REPLACE FUNCTION public.plants_list_seen(p_login uuid, p_plants jsonb, p_mode text DEFAULT 'sync'::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select plants.list_seen(p_login, p_plants, now(), p_mode)
$function$;
