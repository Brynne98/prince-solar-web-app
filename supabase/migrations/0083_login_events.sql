-- ============================================================================
-- 0083 — keep a row each time a SunSynk login dies or is linked again (SOLAR-111).
--
-- Brynne's two logins needed Reconnect on 1 Oct and 15 Oct; the family's login
-- has run since 16 Sep without. The reason was lost both times: account_mark
-- writes it to last_error and account_upsert wipes it on the next link. She had
-- signed in to the SunSynk app or website around both dates, which fits 0063's
-- guess that SunSynk keeps one live sign-in per login. These rows let the next
-- death be lined up against that.
--
-- A dead refresh token is only found when poll next refreshes, so each row keeps
-- the two times that bound the real death:
--   last_ok_at         last poll that worked
--   access_expires_at  set at the last good refresh to about 7 days ahead
--                      (expires_in less EXPIRY_MARGIN_S, _shared/sunsynk.ts)
--
-- account_upsert and account_mark are 0063's bodies plus the insert.
-- ============================================================================

create table if not exists private.sunsynk_login_events (
  id                 bigint generated always as identity primary key,
  account_id         uuid not null references private.sunsynk_accounts (id) on delete cascade,
  at                 timestamptz not null default now(),
  -- died:     poll marked the login needs_relink
  -- relinked: someone signed in again on Connect; reason holds the status and
  --           last_error the row had just before
  event              text not null check (event in ('died', 'relinked')),
  reason             text,
  last_ok_at         timestamptz,
  access_expires_at  bigint
);
create index if not exists sunsynk_login_events_account_idx
  on private.sunsynk_login_events (account_id, at);
revoke all on table private.sunsynk_login_events from public, anon, authenticated;

create or replace function public.account_upsert(
  p_user uuid, p_username text, p_access text, p_expires bigint)
returns uuid
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare acc uuid;
begin
  -- Before the upsert below wipes status and last_error. A first link has no row.
  insert into private.sunsynk_login_events (account_id, event, reason, last_ok_at, access_expires_at)
  select id, 'relinked', status || coalesce(': ' || last_error, ''), last_ok_at, access_expires_at
    from private.sunsynk_accounts
   where user_id = p_user and sunsynk_username = p_username;

  insert into private.sunsynk_accounts (user_id, sunsynk_username, access_token, access_expires_at, status, last_ok_at, last_error)
  values (p_user, p_username, p_access, p_expires, 'active', now(), null)
  on conflict (user_id, sunsynk_username) do update
    set access_token = excluded.access_token,
        access_expires_at = excluded.access_expires_at,
        status = 'active', last_ok_at = now(), last_error = null
  returning id into acc;
  -- A fresh sign-in replaces whatever the other copies held. The refresh token
  -- follows in account_refresh_set, which link-sunsynk calls next.
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires, status = 'active', last_error = null
   where id in (select private.login_copies(acc));
  return acc;
end $$;

create or replace function public.account_mark(p_account uuid, p_status text, p_error text)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  -- One row for the account poll was working on; its copies die with it below.
  insert into private.sunsynk_login_events (account_id, event, reason, last_ok_at, access_expires_at)
  select id, 'died', p_error, last_ok_at, access_expires_at
    from private.sunsynk_accounts
   where id = p_account and p_status = 'needs_relink';
  update private.sunsynk_accounts set status = p_status, last_error = p_error where id = p_account;
  -- A dead sign-in is dead for every copy holding that same refresh token. A copy
  -- with a different (newer) token, or a row with none, keeps its own status, and
  -- other errors stay with the row.
  update private.sunsynk_accounts set status = p_status, last_error = p_error
   where p_status = 'needs_relink' and id in (select private.login_copies(p_account))
     and public.account_refresh_get(id) = public.account_refresh_get(p_account);
$$;
