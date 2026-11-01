-- ============================================================================
-- 0135 — a login that works gives its try back (SOLAR-278).
--
-- 0107 counts every link attempt, good or bad, 5 an hour. A user adding 3 good
-- logins and mistyping twice was locked out for an hour. link_attempt still
-- takes a place before SunSynk is called, so two requests at once can't both
-- slip past the cap; link-sunsynk now calls link_succeeded after a good link,
-- which removes that user's newest attempt. Only failed tries stay counted.
-- ============================================================================

create or replace function public.link_succeeded(p_user uuid)
returns void
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  perform pg_advisory_xact_lock(hashtext('link_attempt:' || p_user::text));
  delete from private.link_attempts
  where ctid = (select ctid from private.link_attempts
                where user_id = p_user order by at desc limit 1);
end $$;
revoke all on function public.link_succeeded(uuid) from public, anon, authenticated;
grant execute on function public.link_succeeded(uuid) to service_role;
