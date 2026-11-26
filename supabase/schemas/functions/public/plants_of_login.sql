CREATE OR REPLACE FUNCTION public.plants_of_login(p_login uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'vendor_id', p.vendor_id) order by p.id), '[]'::jsonb)
    from plants.login_plants lp join plants.plants p on p.id = lp.plant where lp.login = p_login
$function$;
