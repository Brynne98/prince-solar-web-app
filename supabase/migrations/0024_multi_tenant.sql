-- ============================================================================
-- 0024 — multi-tenant foundation.
--
-- Until now the deployment was one SunSynk account, one plant, one dashboard user.
-- This migration makes three structural changes so that many users can each link
-- their own SunSynk account:
--
--   1. private.sunsynk_accounts replaces private.auth. One row per linked SunSynk
--      login. The refresh token lives in Vault (encrypted at rest, keys held by
--      Supabase, never readable through PostgREST); only its Vault id is stored
--      here. The password is never stored anywhere — the link function exchanges
--      it for a token and forgets it.
--
--   2. public.plant_users maps a SunSynk plant to the dashboard user who may see
--      it. This is the tenancy boundary. RLS on every data table now joins through
--      it via my_plant_ids().
--
--   3. plant_id is added to agg_minute, readings and strings. agg_minute was keyed
--      on ts alone — one row per minute for the whole deployment — which is
--      single-tenant by construction. Its key becomes (plant_id, ts).
--
-- Existing rows are backfilled from private.meta, which the poller has always
-- populated with each inverter's plant_id. The migration refuses to run if it
-- finds more than one distinct plant in meta, because then the agg_minute
-- backfill would be ambiguous.
--
-- NOTE: the api_* RPCs are SECURITY DEFINER and bypass RLS. They are scoped to
-- the caller's plants in 0025. Until that lands, do not link a second account.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Linked SunSynk accounts
-- ---------------------------------------------------------------------------
create table if not exists private.sunsynk_accounts (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users (id) on delete cascade,
  sunsynk_username   text not null,
  -- vault.secrets.id holding the refresh token; null until first successful link
  refresh_secret_id  uuid,
  access_token       text,
  access_expires_at  bigint,
  -- active:       polled every minute
  -- needs_relink: refresh failed (password changed, token revoked); polling paused,
  --               user is prompted to re-enter credentials
  -- disabled:     user disconnected; kept for history, not polled
  status             text not null default 'active'
                     check (status in ('active', 'needs_relink', 'disabled')),
  linked_at          timestamptz not null default now(),
  last_ok_at         timestamptz,
  last_error         text,
  unique (user_id, sunsynk_username)
);
create index if not exists sunsynk_accounts_status_idx on private.sunsynk_accounts (status);

-- The single-tenant token row is superseded. Its accessors go with it.
drop function if exists public.auth_token_get();
drop function if exists public.auth_token_set(text, text, bigint);
drop function if exists public.auth_token_expire();
drop table if exists private.auth;

-- ---------------------------------------------------------------------------
-- 2. Plant → user mapping (the tenancy boundary)
-- ---------------------------------------------------------------------------
create table if not exists public.plant_users (
  plant_id    bigint not null,
  user_id     uuid   not null references auth.users (id) on delete cascade,
  account_id  uuid   references private.sunsynk_accounts (id) on delete set null,
  plant_name  text,
  linked_at   timestamptz not null default now(),
  primary key (plant_id, user_id)
);
create index if not exists plant_users_user_idx on public.plant_users (user_id);

alter table public.plant_users enable row level security;
drop policy if exists plant_users_read on public.plant_users;
create policy plant_users_read on public.plant_users
  for select to authenticated using (user_id = auth.uid());
revoke all on public.plant_users from anon;
grant select on public.plant_users to authenticated;
grant select, insert, update, delete on public.plant_users to service_role;

-- The set of plants the calling user may see. STABLE so the planner evaluates it
-- once per statement rather than per row; SECURITY INVOKER so it sees auth.uid().
create or replace function public.my_plant_ids()
returns setof bigint
language sql
stable
security invoker
set search_path = public, pg_temp
as $$ select plant_id from public.plant_users where user_id = auth.uid() $$;
grant execute on function public.my_plant_ids() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. plant_id on the data tables
-- ---------------------------------------------------------------------------
do $$
declare
  n_plants int;
  the_plant bigint;
begin
  select count(distinct plant_id), min(plant_id)
    into n_plants, the_plant
    from private.meta where plant_id is not null;

  if n_plants > 1 then
    raise exception '0024: % distinct plants in private.meta; agg_minute backfill is ambiguous', n_plants;
  end if;

  -- readings / strings: backfill by serial from meta, then any stragglers to the
  -- one known plant (rows from before meta was populated).
  alter table public.readings add column if not exists plant_id bigint;
  update public.readings r set plant_id = m.plant_id
    from private.meta m where r.sn = m.sn and r.plant_id is null and m.plant_id is not null;
  if the_plant is not null then
    update public.readings set plant_id = the_plant where plant_id is null;
  end if;

  alter table public.strings add column if not exists plant_id bigint;
  update public.strings s set plant_id = m.plant_id
    from private.meta m where s.sn = m.sn and s.plant_id is null and m.plant_id is not null;
  if the_plant is not null then
    update public.strings set plant_id = the_plant where plant_id is null;
  end if;

  -- agg_minute: no serial to join on; every existing row belongs to the one plant.
  alter table public.agg_minute add column if not exists plant_id bigint;
  if the_plant is not null then
    update public.agg_minute set plant_id = the_plant where plant_id is null;
  end if;

  -- Only enforce NOT NULL if nothing is left unassigned (a fresh local stack has
  -- no rows and no meta, and must not fail here).
  if not exists (select 1 from public.readings   where plant_id is null)
 and not exists (select 1 from public.strings    where plant_id is null)
 and not exists (select 1 from public.agg_minute where plant_id is null) then
    alter table public.readings   alter column plant_id set not null;
    alter table public.strings    alter column plant_id set not null;
    alter table public.agg_minute alter column plant_id set not null;
  else
    raise exception '0024: rows with null plant_id remain after backfill';
  end if;
end $$;

-- agg_minute is now per plant.
alter table public.agg_minute drop constraint if exists agg_minute_pkey;
alter table public.agg_minute add primary key (plant_id, ts);
create index if not exists agg_minute_ts_idx on public.agg_minute (ts desc);

create index if not exists readings_plant_ts_idx on public.readings (plant_id, ts desc);
create index if not exists strings_plant_ts_idx  on public.strings  (plant_id, ts desc);

-- private.inverters: which account polls each serial
alter table private.inverters add column if not exists account_id uuid
  references private.sunsynk_accounts (id) on delete set null;

-- Logger-offline windows are per plant now. Existing rows belong to the one plant.
alter table private.gaps add column if not exists plant_id bigint;
do $$
declare the_plant bigint;
begin
  select min(plant_id) into the_plant from private.meta where plant_id is not null;
  if the_plant is not null then update private.gaps set plant_id = the_plant where plant_id is null; end if;
  if exists (select 1 from private.gaps where plant_id is null) then
    delete from private.gaps where plant_id is null; -- orphan windows with no plant to recover into
  end if;
end $$;
alter table private.gaps alter column plant_id set not null;
alter table private.gaps drop constraint if exists gaps_pkey;
alter table private.gaps add primary key (plant_id, from_ts);

drop function if exists public.gap_record(bigint, bigint);
create or replace function public.gap_record(p_plant bigint, p_from bigint, p_to bigint)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  insert into private.gaps (plant_id, from_ts, to_ts) values (p_plant, p_from, p_to)
  on conflict (plant_id, from_ts) do nothing
$$;

drop function if exists public.gaps_list();
create or replace function public.gaps_list()
returns table (plant_id bigint, from_ts bigint, to_ts bigint)
language sql
security definer
set search_path = private, pg_temp
as $$ select plant_id, from_ts, to_ts from private.gaps order by plant_id, from_ts $$;

-- ---------------------------------------------------------------------------
-- 4. RLS: authenticated users see only their own plants
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['agg_minute', 'readings', 'strings', 'plant_energy'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format(
      'create policy %I on public.%I for select to authenticated
         using (plant_id in (select public.my_plant_ids()))',
      t || '_read', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Vault-backed refresh token accessors (service_role only)
-- ---------------------------------------------------------------------------
-- Vault secrets are opaque to PostgREST; the only route is these definer
-- functions, and only service_role may execute them.

create or replace function public.account_refresh_set(p_account uuid, p_refresh text)
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

create or replace function public.account_refresh_get(p_account uuid)
returns text
language sql
security definer
set search_path = private, vault, pg_temp
as $$
  select ds.decrypted_secret
    from private.sunsynk_accounts a
    join vault.decrypted_secrets ds on ds.id = a.refresh_secret_id
   where a.id = p_account
$$;

-- ---------------------------------------------------------------------------
-- 6. Account accessors for the poller and the link function (service_role only)
-- ---------------------------------------------------------------------------
create or replace function public.accounts_active()
returns table (id uuid, user_id uuid, sunsynk_username text, access_token text, access_expires_at bigint)
language sql
security definer
set search_path = private, pg_temp
as $$
  select id, user_id, sunsynk_username, access_token, access_expires_at
    from private.sunsynk_accounts
   where status = 'active'
   order by linked_at
$$;

create or replace function public.account_by_username(p_username text)
returns table (id uuid, user_id uuid, status text)
language sql
security definer
set search_path = private, pg_temp
as $$
  select id, user_id, status from private.sunsynk_accounts where sunsynk_username = p_username
$$;

-- Create or reactivate. A user re-linking after needs_relink lands here too.
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
  return acc;
end $$;

create or replace function public.account_access_set(p_account uuid, p_access text, p_expires bigint)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires, last_ok_at = now(), last_error = null
   where id = p_account
$$;

create or replace function public.account_mark(p_account uuid, p_status text, p_error text)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  update private.sunsynk_accounts set status = p_status, last_error = p_error where id = p_account
$$;

-- The user-facing disconnect: wipes the token, keeps the row for history.
create or replace function public.account_disable(p_account uuid)
returns void
language plpgsql
security definer
set search_path = private, vault, pg_temp
as $$
declare sid uuid;
begin
  select refresh_secret_id into sid from private.sunsynk_accounts where id = p_account;
  update private.sunsynk_accounts
     set status = 'disabled', access_token = null, access_expires_at = null, refresh_secret_id = null
   where id = p_account;
  if sid is not null then delete from vault.secrets where id = sid; end if;
end $$;

-- After a link: record which plants this user may see, and which account polls them.
create or replace function public.plant_users_upsert(p_user uuid, p_account uuid, p_rows jsonb)
returns void
language sql
security definer
set search_path = public, private, pg_temp
as $$
  insert into public.plant_users (plant_id, user_id, account_id, plant_name)
  select (r->>'plant_id')::bigint, p_user, p_account, r->>'plant_name'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id, user_id) do update
    set account_id = excluded.account_id, plant_name = excluded.plant_name
$$;

-- inverters_seed now also records the polling account.
create or replace function public.inverters_seed(p_rows jsonb)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  insert into private.inverters (sn, plant_id, account_id)
  select r->>'sn', nullif(r->>'plant_id', '')::bigint, nullif(r->>'account_id', '')::uuid
    from jsonb_array_elements(p_rows) r
  on conflict (sn) do update
    set plant_id = excluded.plant_id, account_id = excluded.account_id
$$;

-- ---------------------------------------------------------------------------
-- 7. What the signed-in user may see about their own link (authenticated)
-- ---------------------------------------------------------------------------
-- Status only — never tokens. Drives the "Connect / Re-link / Connected" screen.
create or replace function public.api_link_status()
returns table (account_id uuid, sunsynk_username text, status text, linked_at timestamptz,
               last_ok_at timestamptz, plants jsonb)
language sql
security definer
set search_path = public, private, pg_temp
as $$
  select a.id, a.sunsynk_username, a.status, a.linked_at, a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name))
                     from public.plant_users pu where pu.account_id = a.id and pu.user_id = auth.uid()),
                  '[]'::jsonb)
    from private.sunsynk_accounts a
   where a.user_id = auth.uid()
   order by a.linked_at desc
$$;

-- The user disconnects their own account. Only their own.
create or replace function public.api_link_disconnect(p_account uuid)
returns void
language plpgsql
security definer
set search_path = public, private, vault, pg_temp
as $$
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and user_id = auth.uid()) then
    raise exception 'not your account';
  end if;
  perform public.account_disable(p_account);
  delete from public.plant_users where account_id = p_account and user_id = auth.uid();
end $$;

-- ---------------------------------------------------------------------------
-- 8. Grants
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  -- service_role only
  foreach f in array array[
    'account_refresh_set(uuid,text)',
    'account_refresh_get(uuid)',
    'accounts_active()',
    'account_by_username(text)',
    'account_upsert(uuid,text,text,bigint)',
    'account_access_set(uuid,text,bigint)',
    'account_mark(uuid,text,text)',
    'account_disable(uuid)',
    'plant_users_upsert(uuid,uuid,jsonb)',
    'inverters_seed(jsonb)',
    'gap_record(bigint,bigint,bigint)',
    'gaps_list()'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;

  -- authenticated (self-scoped by auth.uid() inside)
  foreach f in array array['api_link_status()', 'api_link_disconnect(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
