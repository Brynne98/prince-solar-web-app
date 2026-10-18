-- ============================================================================
-- 0086 — tester places and the waiting list in the admin console (SOLAR-130).
--
-- Same lock as 0084: each function raises 42501 unless auth.uid() is in
-- private.admins. admin_testers() reads places (0085) and the waiting list;
-- the others set places and delete waiting-list emails, one or all.
-- ============================================================================

create or replace function private.require_admin()
returns void
language plpgsql
stable security definer
set search_path = private, pg_temp
as $$
begin
  if auth.uid() is null or not exists (select 1 from private.admins where user_id = auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
end $$;
revoke all on function private.require_admin() from public, anon, authenticated;

create or replace function public.admin_testers()
returns jsonb
language plpgsql
stable security definer
set search_path = private, pg_temp
as $$
begin
  perform private.require_admin();
  return public.api_tester_places() || jsonb_build_object(
    'waitlist', (select coalesce(jsonb_agg(jsonb_build_object('email', w.email, 'at', w.created_at)
                                           order by w.created_at desc), '[]'::jsonb)
                   from private.waitlist w));
end $$;

create or replace function public.admin_set_tester_places(p_places int)
returns void
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  perform private.require_admin();
  if p_places is null or p_places < 0 then
    raise exception 'places must be 0 or more' using errcode = '22023';
  end if;
  -- One row; the where is for pg-safeupdate, which refuses an update without one.
  update private.tester_places set places = p_places where id;
end $$;

-- p_email null deletes the whole list.
create or replace function public.admin_waitlist_delete(p_email text default null)
returns int
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare n int;
begin
  perform private.require_admin();
  delete from private.waitlist where p_email is null or email = lower(btrim(p_email));
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.admin_testers() from public, anon;
revoke all on function public.admin_set_tester_places(int) from public, anon;
revoke all on function public.admin_waitlist_delete(text) from public, anon;
grant execute on function public.admin_testers() to authenticated;
grant execute on function public.admin_set_tester_places(int) to authenticated;
grant execute on function public.admin_waitlist_delete(text) to authenticated;
