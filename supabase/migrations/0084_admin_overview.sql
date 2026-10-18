-- ============================================================================
-- 0084 — read-only admin overview for admin.princesolarhub.com (SOLAR-115).
--
-- private.admins lists who may call admin_overview(). Nobody but the table
-- owner reads it. admin_overview() is SECURITY DEFINER and raises 42501 unless
-- auth.uid() is in that list, so a signed-in user who is not an admin
-- gets an error and no rows. Nothing here is reachable through api_* or table
-- grants. Cloudflare Access sits in front of the site as a second lock.
-- ============================================================================
create table if not exists private.admins (
  user_id  uuid primary key references auth.users (id) on delete cascade,
  added_at timestamptz not null default now()
);
revoke all on table private.admins from public, anon, authenticated;

insert into private.admins (user_id)
select id from auth.users where email = 'brynneprince98@gmail.com'
on conflict do nothing;

-- One call for the whole page. Light on purpose (quota): the freshness read is
-- one primary-key probe per plant, errors are capped at 50 rows.
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable security definer
set search_path = public, pg_temp
as $$
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
               'plants', (select count(*) from public.plant_users pu where pu.user_id = u.id),
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
        from public.plant_users pu
        join auth.users u on u.id = pu.user_id),
    'logins', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'email', u.email,
               'sunsynkUser', s.sunsynk_username,
               'status', s.status,
               'linkedAt', s.linked_at,
               'lastOkAt', s.last_ok_at,
               'lastError', left(s.last_error, 300)
             ) order by u.email, s.linked_at), '[]'::jsonb)
        from private.sunsynk_accounts s
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
end $$;
revoke all on function public.admin_overview() from public, anon;
grant execute on function public.admin_overview() to authenticated;
