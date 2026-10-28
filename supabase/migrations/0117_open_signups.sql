-- ============================================================================
-- 0117 — sign-ups open to everyone (SOLAR-214).
--
-- hook_tester_places (0085) is still the before-user-created auth hook in the
-- dashboard; it now lets every sign-up through, so the dashboard switch doesn't
-- matter. New accounts start on Free (0110).
--
-- Nothing calls the waiting list or the places count any more: anon and signed-in
-- users lose them, so the waiting list can't be filled from outside. The tables
-- and their rows stay (private.tester_places, private.waitlist), and the admin
-- console still reads them through admin_testers (0086, definer).
-- ============================================================================

create or replace function public.hook_tester_places(event jsonb)
returns jsonb
language sql
stable security definer
set search_path = private, pg_temp
as $$
  select '{}'::jsonb
$$;

revoke execute on function public.api_join_waitlist(text) from anon, authenticated;
revoke execute on function public.api_tester_places() from anon, authenticated;
