-- ============================================================================
-- 0085 — cap new sign-ups at a number of tester places, keep a waiting list
-- for the rest (SOLAR-124).
--
-- private.tester_places holds one row: how many places, and from when accounts
-- count against them. Brynne and her father signed up before 18 Oct 2026, so
-- they don't use a place. To allow more testers, change `places` in the table
-- editor (schema private). Nothing else needs to change.
--
-- hook_tester_places is a before-user-created auth hook. It covers email and
-- Google sign-up alike. It only works once switched on: locally in
-- supabase/config.toml, in production in the dashboard under Auth > Hooks.
-- An email sign-up that is never confirmed holds its place for a day only, so
-- typos and junk sign-ups can't use the places up. Two sign-ups in the same
-- instant can both get the last place; at this size that's fine.
-- ============================================================================

create table if not exists private.tester_places (
  id            boolean primary key default true check (id),
  places        int not null check (places >= 0),
  counted_from  timestamptz not null
);
insert into private.tester_places (places, counted_from)
values (10, '2026-10-18 00:00:00+02')
on conflict (id) do nothing;
revoke all on table private.tester_places from public, anon, authenticated;

-- People who asked to hear when the app opens to everyone.
create table if not exists private.waitlist (
  email       text primary key,
  created_at  timestamptz not null default now()
);
revoke all on table private.waitlist from public, anon, authenticated;

-- Places and how many are left. Read by the sign-up screen and the website,
-- before anyone is signed in.
create or replace function public.api_tester_places()
returns jsonb
language sql
stable security definer
set search_path = private, pg_temp
as $$
  select jsonb_build_object(
    'places', t.places,
    'left', greatest(t.places - (select count(*) from auth.users u
                              where u.created_at >= t.counted_from
                                and (u.email_confirmed_at is not null or u.created_at > now() - interval '1 day')), 0))
  from private.tester_places t;
$$;
revoke execute on function public.api_tester_places() from public;
grant execute on function public.api_tester_places() to anon, authenticated;

create or replace function public.api_join_waitlist(p_email text)
returns void
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare e text := lower(btrim(p_email));
begin
  if e is null or length(e) > 254 or e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email' using errcode = '22023';
  end if;
  insert into private.waitlist (email) values (e) on conflict (email) do nothing;
end;
$$;
revoke execute on function public.api_join_waitlist(text) from public;
grant execute on function public.api_join_waitlist(text) to anon, authenticated;

create or replace function public.hook_tester_places(event jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path = private, pg_temp
as $$
begin
  -- No row (deleted by mistake) means no cap, not a closed door.
  if coalesce((public.api_tester_places() ->> 'left')::int, 1) > 0 then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'Tester places are full.'));
end;
$$;
revoke execute on function public.hook_tester_places(jsonb) from public, anon, authenticated;
grant execute on function public.hook_tester_places(jsonb) to supabase_auth_admin;
