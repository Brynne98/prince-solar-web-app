CREATE OR REPLACE FUNCTION public.api_notifications()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with n as (
    select q.id, q.kind, q.plant_id, pu.plant_name, q.read_at, q.created_at, q.data
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid()
       and q.plant_id in (select public.my_plant_ids())
       and private.is_alert(q.kind)
       and q.created_at > now() - interval '30 days'
     order by q.created_at desc, q.id desc
     limit 300)
  select jsonb_build_object(
    'pinned', '[]'::jsonb,
    'unread', (select count(*) from n where read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'plant', plant_id, 'plantName', plant_name, 'read', read_at is not null) || jsonb_build_object(   -- 0265: no old words
        'data', data, 'created', extract(epoch from created_at), 'tz', public.plant_tz(plant_id),        -- 0264
        'switch', private.alert_group(kind))
        order by created_at desc, id desc) from n), '[]'::jsonb));
$function$;
