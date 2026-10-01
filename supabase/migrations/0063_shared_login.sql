-- ============================================================================
-- 0063 — copies of one SunSynk login share one sign-in. (BP-271)
--
-- Two dashboard users can link the same SunSynk login (a family's plant, seen by
-- the family and by Brynne). Each link did its own password sign-in and kept its
-- own tokens. On 16 Sep the family linked tshigabe@…; on 19 Sep Brynne's older
-- copy failed its first refresh after that, with SunSynk's "dead refresh token"
-- answer. SunSynk most likely keeps one live sign-in per login, so every new link
-- quietly kills the copies before it. Not proven, and this does not depend on it:
-- holding one sign-in for all copies is right either way.
--
-- A "copy" is another row with the same provider and username (any case) that has
-- not been disconnected. From here on:
--   * a new access token (refresh, or a link) goes to every copy and revives it;
--   * a new refresh token goes to every copy, each in its own Vault secret, so
--     disconnecting one copy (account_disable deletes its secret) leaves the rest;
--   * needs_relink on one copy marks them all, since they hold the same tokens.
-- Plant access is unchanged: plant_users still records which user linked which
-- plant, and nothing here adds a row to it.
--
-- Finally, a dead copy whose login still has a working copy takes that copy's
-- tokens now, so nobody needs the other household's password.
-- ============================================================================

-- Every other live copy of this account's login.
create or replace function private.login_copies(p_account uuid)
returns setof uuid
language sql
stable
security definer
set search_path = private, pg_temp
as $$
  select o.id
    from private.sunsynk_accounts a
    join private.sunsynk_accounts o
      on o.provider = a.provider and lower(o.sunsynk_username) = lower(a.sunsynk_username)
   where a.id = p_account and o.id <> p_account and o.status <> 'disabled'
$$;
revoke all on function private.login_copies(uuid) from public, anon, authenticated;

-- The 0024 body of account_refresh_set, for one row: replace its Vault secret.
create or replace function private.refresh_store(p_account uuid, p_refresh text)
returns void
language plpgsql
security definer
set search_path = private, vault, pg_temp
as $$
declare
  old_id uuid;
  new_id uuid;
begin
  -- Vault secret names are unique, so the old one must go before the new one is
  -- created under the same name. Same transaction: there is never a moment with
  -- no secret on file.
  select refresh_secret_id into old_id from private.sunsynk_accounts where id = p_account;
  if old_id is not null then
    update private.sunsynk_accounts set refresh_secret_id = null where id = p_account;
    delete from vault.secrets where id = old_id;
  end if;
  new_id := vault.create_secret(p_refresh, 'sunsynk_refresh_' || p_account::text,
                                'SunSynk refresh token for account ' || p_account::text);
  update private.sunsynk_accounts set refresh_secret_id = new_id where id = p_account;
end $$;
revoke all on function private.refresh_store(uuid, text) from public, anon, authenticated;

create or replace function public.account_refresh_set(p_account uuid, p_refresh text)
returns void
language plpgsql
security definer
set search_path = private, vault, pg_temp
as $$
declare c uuid;
begin
  perform private.refresh_store(p_account, p_refresh);
  for c in select private.login_copies(p_account) loop
    perform private.refresh_store(c, p_refresh);
  end loop;
end $$;

create or replace function public.account_access_set(p_account uuid, p_access text, p_expires bigint)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires, last_ok_at = now(), last_error = null
   where id = p_account;
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires, status = 'active', last_error = null
   where id in (select private.login_copies(p_account));
$$;

create or replace function public.account_upsert(
  p_user uuid, p_username text, p_access text, p_expires bigint)
returns uuid
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare acc uuid;
begin
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
  update private.sunsynk_accounts set status = p_status, last_error = p_error where id = p_account;
  -- A dead sign-in is dead for every copy holding that same refresh token. A copy
  -- with a different (newer) token, or a row with none, keeps its own status, and
  -- other errors stay with the row.
  update private.sunsynk_accounts set status = p_status, last_error = p_error
   where p_status = 'needs_relink' and id in (select private.login_copies(p_account))
     and public.account_refresh_get(id) = public.account_refresh_get(p_account);
$$;

-- Revive dead copies from a working one: the most recently served copy wins.
do $$
declare
  r record;
  tok text;
begin
  for r in
    select d.id as dead, l.id as live, l.access_token, l.access_expires_at
      from private.sunsynk_accounts d
      cross join lateral (
        select o.id, o.access_token, o.access_expires_at
          from private.sunsynk_accounts o
         where o.provider = d.provider and lower(o.sunsynk_username) = lower(d.sunsynk_username)
           and o.status = 'active' and o.refresh_secret_id is not null
         order by o.last_ok_at desc nulls last
         limit 1) l
     where d.status = 'needs_relink'
  loop
    tok := public.account_refresh_get(r.live);
    continue when tok is null;
    perform private.refresh_store(r.dead, tok);
    update private.sunsynk_accounts
       set access_token = r.access_token, access_expires_at = r.access_expires_at,
           status = 'active', last_error = null
     where id = r.dead;
    raise notice 'login copy % revived from %', r.dead, r.live;
  end loop;
end $$;
