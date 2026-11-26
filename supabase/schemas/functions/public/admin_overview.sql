CREATE OR REPLACE FUNCTION public.admin_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null or not exists (select 1 from private.admins where user_id = auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'at', now(),
    'users', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'email', u.email,
               'provider', u.raw_app_meta_data->>'provider',
               'createdAt', u.created_at,
               'lastSignInAt', u.last_sign_in_at,
               'plants', (select count(*) from plants.user_plants pu where pu.user_id = u.id),
               'admin', exists (select 1 from private.admins a where a.user_id = u.id)
             ) order by u.created_at), '[]'::jsonb)
        from auth.users u),
    'plants', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'plantId', pu.plant_id,
               'name', pu.plant_name,
               'email', u.email,
               'linkedAt', pu.linked_at,
               'inverters', (select count(*) from private.meta m where m.plant_id = pu.plant_id),
               'lastTs', (select a.ts from public.agg_minute a
                           where a.plant_id = pu.plant_id order by a.ts desc limit 1)
             ) order by u.email, pu.plant_id), '[]'::jsonb)
        from plants.user_plants pu
        join auth.users u on u.id = pu.user_id),
    'logins', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'email', u.email,
               'sunsynkUser', s.username,
               'status', s.status,
               'linkedAt', s.linked_at,
               'lastOkAt', s.last_ok_at,
               'lastError', left(s.last_error, 300)
             ) order by u.email, s.linked_at), '[]'::jsonb)
        from plants.logins s
        join auth.users u on u.id = s.user_id),
    'errors', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'at', e.at,
               'email', u.email,
               'plantId', e.plant_id,
               'version', e.app_version,
               'page', e.page,
               'message', left(e.message, 300)
             ) order by e.at desc), '[]'::jsonb)
        from (select * from public.client_errors order by at desc limit 50) e
        left join auth.users u on u.id = e.user_id)
  );
end $function$;
