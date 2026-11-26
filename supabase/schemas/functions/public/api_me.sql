CREATE OR REPLACE FUNCTION public.api_me()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'user', jsonb_build_object('id', auth.uid()),
    'prefs', coalesce((select prefs from public.profiles where user_id = auth.uid()), '{}'::jsonb),
    'plants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pu.plant_id, 'name', pu.plant_name, 'linkedAt', pu.linked_at,
               'config', to_jsonb(c) - 'plant_id' - 'updated_by')
             order by pu.linked_at, pu.plant_id)
        from public.plant_users pu
        left join public.plant_config c on c.plant_id = pu.plant_id
       where pu.user_id = auth.uid() and pu.plant_id in (select public.my_plant_ids())), '[]'::jsonb))
$function$;
