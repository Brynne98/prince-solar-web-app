-- ============================================================================
-- 0107 — cap SunSynk link attempts per user (SOLAR-138 item 5).
--
-- link-sunsynk sent every attempt straight to SunSynk. Sign-up is open, so one
-- user could try logins without end, and SunSynk could block the function's
-- address or lock accounts. That would stop polling for everyone.
--
-- link-sunsynk now calls link_attempt(user) before it talks to SunSynk. It
-- counts every attempt, good or bad, in the last hour. At 5 it answers false and
-- the function refuses with 429. Rows older than an hour are deleted on the next
-- call, so the table stays a few rows per user.
--
-- private.sunsynk_login_events was the ticket's suggestion, but its rows need an
-- account, and a rejected login has none. So a table of its own.
-- ============================================================================

create table if not exists private.link_attempts (
  user_id  uuid not null references auth.users (id) on delete cascade,
  at       timestamptz not null default now()
);
create index if not exists link_attempts_user_idx on private.link_attempts (user_id, at);
revoke all on table private.link_attempts from public, anon, authenticated;

create or replace function public.link_attempt(p_user uuid)
returns boolean
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  -- One caller at a time per user, so two requests at once can't both get the 5th place.
  perform pg_advisory_xact_lock(hashtext('link_attempt:' || p_user::text));
  delete from private.link_attempts where user_id = p_user and at < now() - interval '1 hour';
  if (select count(*) from private.link_attempts where user_id = p_user) >= 5 then
    return false;
  end if;
  insert into private.link_attempts (user_id) values (p_user);
  return true;
end $$;
revoke all on function public.link_attempt(uuid) from public, anon, authenticated;
grant execute on function public.link_attempt(uuid) to service_role;
