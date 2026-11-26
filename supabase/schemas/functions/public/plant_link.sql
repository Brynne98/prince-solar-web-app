CREATE OR REPLACE FUNCTION public.plant_link(p_user uuid, p_plant bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('linked_at', u.linked_at, 'plant_name', u.plant_name)
    from plants.user_plants u
   where u.plant_id = p_plant and (p_user is null or u.user_id = p_user)
   order by u.share_gone_at is not null, u.linked_at limit 1
$function$;
