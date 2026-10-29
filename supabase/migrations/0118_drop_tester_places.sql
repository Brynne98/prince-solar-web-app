-- ============================================================================
-- 0118 — tester places and the waiting list are gone (SOLAR-219).
--
-- Sign-ups opened in 0117 and left these doing nothing. Before this runs in
-- production, switch off the before-user-created hook in the dashboard
-- (Auth > Hooks): auth refuses every sign-up while it points at a missing
-- function. The waiting list was emptied before this (SOLAR-187).
-- ============================================================================

drop function if exists public.hook_tester_places(jsonb);
drop function if exists public.admin_testers();
drop function if exists public.admin_set_tester_places(int);
drop function if exists public.admin_waitlist_delete(text);
drop function if exists public.api_join_waitlist(text);
drop function if exists public.api_tester_places();

drop table if exists private.tester_places;
drop table if exists private.waitlist;
