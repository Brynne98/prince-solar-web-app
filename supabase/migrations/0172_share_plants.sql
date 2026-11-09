-- ============================================================================
-- 0172 — owners share their plant to us instead of giving us their password (SOLAR-310)
--
-- The owner shares the plant in the SunSynk app to our company login as Visitor.
-- One stored login (kind 'share') reads every plant shared to it. Its username and
-- password are function secrets (SUNSYNK_SHARE_USERNAME / _PASSWORD), never here;
-- the row belongs to an auth user for that address, made by the claim function.
--
-- A shared plant has no owner until someone claims it (claim-share function): the
-- plant id or an inverter serial, checked live against the share login's list.
-- Then a plant_users row like any other, via_share, read through the share login.
--   * One live claim per plant; a plant someone already has (shared or by password)
--     can't be claimed. The owner is told and can remove the share in SunSynk,
--     which lapses the claim, then share again and claim it.
--   * share_sync (poll, hourly): a claimed plant missing from the list twice an hour
--     apart stops (share_gone_at) and its owner gets one share_removed email. Shared
--     again, it starts when its owner presses Check, not on its own: else a squatter's
--     stopped claim would come back before the owner could take the plant.
--   * poll_jobs leaves out stopped shared plants, and paused plants (0110's rule,
--     which plantsToPoll kept and poll_jobs missed).
-- ============================================================================

alter table private.sunsynk_accounts
  add column if not exists kind text not null default 'login' check (kind in ('login', 'share'));
create unique index if not exists sunsynk_accounts_one_share on private.sunsynk_accounts (kind) where kind = 'share';

alter table public.plant_users
  add column if not exists via_share boolean not null default false,
  add column if not exists share_missing_at timestamptz,
  add column if not exists share_gone_at timestamptz;
create unique index if not exists plant_users_one_share_claim on public.plant_users (plant_id)
  where via_share and share_gone_at is null;

-- ---------------------------------------------------------------------------
-- The share login
-- ---------------------------------------------------------------------------
create or replace function public.share_account_get()
returns table (id uuid, user_id uuid, sunsynk_username text, access_token text, access_expires_at bigint, status text)
language sql stable security definer set search_path = private, pg_temp as $$
  select a.id, a.user_id, a.sunsynk_username, a.access_token, a.access_expires_at, a.status
    from private.sunsynk_accounts a where a.kind = 'share'
$$;

-- A fresh sign-in of the share login; the refresh token follows in account_refresh_set.
create or replace function public.share_account_set(p_user uuid, p_username text, p_access text, p_expires bigint)
returns uuid
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare acc uuid;
begin
  acc := public.account_upsert(p_user, p_username, p_access, p_expires);
  update private.sunsynk_accounts set kind = 'share' where id = acc;
  return acc;
end $$;

-- ---------------------------------------------------------------------------
-- Claiming. Returns 'claimed', 'claimed_paused' (plan full: linked stopped, as a
-- password link would be), 'yours' (this user has it already) or 'taken'.
-- ---------------------------------------------------------------------------
create or replace function public.share_claim(p_user uuid, p_account uuid, p_plant bigint, p_plant_name text)
returns text
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  mine public.plant_users;
  lapsed uuid[];
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and kind = 'share' and status <> 'disabled') then
    raise exception 'share_claim: % is not the share login', p_account;
  end if;
  -- plant_users_upsert's order: user, account, plant. Two claims of one plant queue here.
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (SOLAR-438)
  perform private.billing_lock(p_user);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  perform pg_advisory_xact_lock(p_plant);

  select * into mine from public.plant_users where plant_id = p_plant and user_id = p_user;
  if found and (not mine.via_share or mine.share_gone_at is null) then return 'yours'; end if;
  if exists (select 1 from public.plant_users o
              where o.plant_id = p_plant and o.user_id <> p_user and (not o.via_share or o.share_gone_at is null)) then
    return 'taken';
  end if;

  -- A claim that lapsed when the share was removed gives way to this one.
  with d as (delete from public.plant_users
              where plant_id = p_plant and user_id <> p_user and via_share and share_gone_at is not null
             returning user_id)
  select coalesce(array_agg(user_id), '{}') into lapsed from d;
  delete from public.email_queue where plant_id = p_plant and user_id = any (lapsed) and status = 'queued';

  perform public.plant_users_upsert(p_user, p_account,
    jsonb_build_array(jsonb_build_object('plant_id', p_plant, 'plant_name', p_plant_name)));
  update public.plant_users set via_share = true, share_missing_at = null, share_gone_at = null
   where plant_id = p_plant and user_id = p_user;
  -- the free week is per user (0121); the key only records where it came from
  perform public.billing_free_week_start(p_user, 'share:' || p_plant);
  return case when (select paused from public.plant_users where plant_id = p_plant and user_id = p_user)
              then 'claimed_paused' else 'claimed' end;
end $$;

-- ---------------------------------------------------------------------------
-- Hourly: which claimed plants are still shared. p_plants = the share login's list.
-- ---------------------------------------------------------------------------
create or replace function public.share_sync(p_account uuid, p_plants bigint[])
returns jsonb
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  now_s bigint := extract(epoch from now())::bigint;
  back int; missing int; gone int;
begin
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (SOLAR-438)
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));

  -- in the list: a miss is forgotten (a stopped claim waits for its owner's Check)
  update public.plant_users pu set share_missing_at = null
   where pu.account_id = p_account and pu.via_share and pu.plant_id = any (p_plants)
     and pu.share_missing_at is not null and pu.share_gone_at is null;
  get diagnostics back = row_count;

  -- not in the list: first miss noted, so one bad list can't stop a plant
  update public.plant_users pu set share_missing_at = now()
   where pu.account_id = p_account and pu.via_share and pu.share_gone_at is null and pu.share_missing_at is null
     and pu.plant_id <> all (p_plants);
  get diagnostics missing = row_count;

  -- still missing an hour on: stop it and tell the owner once
  with g as (
    update public.plant_users pu set share_gone_at = now()
     where pu.account_id = p_account and pu.via_share and pu.share_gone_at is null
       and pu.share_missing_at < now() - interval '50 minutes' and pu.plant_id <> all (p_plants)
    returning pu.user_id, pu.plant_id, pu.plant_name)
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
  select g.user_id, g.plant_id, 'share_removed', 'share_removed:' || g.plant_id || ':' || now_s,
         jsonb_build_object('plants', jsonb_build_array(coalesce(g.plant_name, 'Plant ' || g.plant_id))), 1
    from g
  on conflict do nothing;
  get diagnostics gone = row_count;

  return jsonb_build_object('back', back, 'missing', missing, 'gone', gone);
end $$;

-- ---------------------------------------------------------------------------
-- 0100's poll_jobs, leaving out stopped shared plants and paused plants
-- ---------------------------------------------------------------------------
create or replace function public.poll_jobs(p_shard int, p_shards int, p_account uuid default null)
returns table (
  plant_id bigint, plant_name text, timezone text, batt_positive_means text,
  backfill_next text, backfill_until text, backfill_tries int,
  temp_next text, temp_tries int, has_grid boolean,
  account_id uuid, user_id uuid, sunsynk_username text, access_token text, access_expires_at bigint)
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  with acc as (
    select a.id, a.user_id, a.sunsynk_username, a.access_token, a.access_expires_at,
           row_number() over (order by a.linked_at, a.id) as rank,
           ('x' || lpad(substr(replace(a.id::text, '-', ''), 1, 8), 16, '0'))::bit(64)::bigint
             % greatest(1, p_shards) as shard
      from private.sunsynk_accounts a
     where a.status = 'active'
  ),
  pick as (
    select distinct on (pu.plant_id) pu.plant_id, pu.plant_name, acc.*
      from public.plant_users pu
      join acc on acc.id = pu.account_id
     where pu.share_gone_at is null and not pu.paused
     order by pu.plant_id, acc.rank
  )
  select p.plant_id, p.plant_name,
         coalesce(c.timezone, 'Africa/Johannesburg'), c.batt_positive_means,
         c.backfill_next::text, c.backfill_until::text, coalesce(c.backfill_tries, 0),
         c.temp_next::text, coalesce(c.temp_tries, 0), c.has_grid,
         p.id, p.user_id, p.sunsynk_username, p.access_token, p.access_expires_at
    from pick p
    left join public.plant_config c on c.plant_id = p.plant_id
   where case when p_account is not null then p.id = p_account else p.shard = p_shard end
   order by p.plant_id
$$;

-- ---------------------------------------------------------------------------
-- 0136's api_link_status, with the share login listed for a user who claimed
-- through it (their plants only), its kind, and each plant's share state.
-- ---------------------------------------------------------------------------
drop function if exists public.api_link_status();
create function public.api_link_status()
 returns table(account_id uuid, sunsynk_username text, status text, linked_at timestamptz, last_ok_at timestamptz, plants jsonb, kind text)
 language sql
 security definer
 set search_path to 'public', 'private', 'pg_temp'
as $function$
  with b as (select bl.*, private.billing_drops(bl) drops from private.billing bl where bl.user_id = auth.uid())
  select a.id, a.sunsynk_username, a.status,
         -- the share login: when this user first claimed through it
         case when a.kind = 'share' then (select min(x.linked_at) from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid())
              else a.linked_at end,
         a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name,
                                                        'paused', pu.paused,
                                                        'inverters', (select count(*) from private.inverters i where i.plant_id = pu.plant_id),
                                                        'remove_on', case when pu.plant_id = any (b.plants_to_remove) then b.remove_on
                                                                          when pu.plant_id = any (b.drops) then b.next_billing_date + 30 end,
                                                        'drop', coalesce(pu.plant_id = any (b.drops), false),
                                                        'free_removal', pu.plant_id = any (b.plants_to_remove) and pu.plant_id = any (b.free_removals),
                                                        -- the owner removed the share in SunSynk (0172)
                                                        'share_gone', pu.share_gone_at is not null)
                                    order by pu.linked_at, pu.plant_id)
                     from public.plant_users pu
                     left join b on b.user_id = pu.user_id
                    where pu.account_id = a.id and pu.user_id = auth.uid()),
                  '[]'::jsonb),
         a.kind
    from private.sunsynk_accounts a
   where a.user_id = auth.uid()
      or (a.kind = 'share' and exists (select 1 from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid()))
   order by 4 desc
$function$;
revoke all on function public.api_link_status() from public, anon;
grant execute on function public.api_link_status() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Removing the share login from Account removes only this user's shared plants.
-- 0139's api_link_remove with that branch; api_link_disconnect is left as it is.
-- ---------------------------------------------------------------------------
create or replace function private.share_release(p_account uuid, p_user uuid)
returns jsonb
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  p bigint;
  mine bigint[];
  gone bigint[];
  orphans bigint[];
begin
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (SOLAR-438)
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  select coalesce(array_agg(plant_id order by plant_id), '{}') into mine
    from public.plant_users where account_id = p_account and user_id = p_user;
  foreach p in array mine loop perform pg_advisory_xact_lock(p); end loop;

  with d as (delete from public.plant_users where account_id = p_account and user_id = p_user returning plant_id)
  select coalesce(array_agg(plant_id order by plant_id), '{}') into gone from d;
  delete from public.email_queue e where e.user_id = p_user and e.plant_id = any (gone) and e.kind not like 'sunsynk_%';

  select coalesce(array_agg(g order by g), '{}') into orphans
    from unnest(gone) g
   where not exists (select 1 from public.plant_users o where o.plant_id = g);
  perform private.plants_tombstone(orphans);
  return jsonb_build_object('plantsRemoved', coalesce(array_length(gone, 1), 0), 'queued', coalesce(array_length(orphans, 1), 0));
end $$;
revoke all on function private.share_release(uuid, uuid) from public, anon, authenticated;

create or replace function public.api_link_remove(p_account uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and user_id = auth.uid())
     and not exists (select 1 from private.sunsynk_accounts a where a.id = p_account and a.kind = 'share'
                       and exists (select 1 from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid())) then
    raise exception 'not your account' using errcode = '42501';
  end if;
  if exists (select 1 from private.sunsynk_accounts where id = p_account and kind = 'share') then
    perform private.share_release(p_account, auth.uid());
  else
    perform public.api_link_disconnect(p_account);
  end if;
  -- plants gone: off the delete lists too
  update private.billing
     set plants_to_remove = array(select x from unnest(plants_to_remove) x
                                   where exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = x)),
         free_removals = array(select x from unnest(free_removals) x
                                where exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = x)),
         updated_at = now()
   where user_id = auth.uid() and cardinality(plants_to_remove) > 0;
  update private.billing set remove_on = null where user_id = auth.uid() and cardinality(plants_to_remove) = 0 and remove_on is not null;
  return jsonb_build_object('result', 'removed');
end $$;

revoke all on function public.share_account_get() from public, anon, authenticated;
revoke all on function public.share_account_set(uuid, text, text, bigint) from public, anon, authenticated;
revoke all on function public.share_claim(uuid, uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.share_sync(uuid, bigint[]) from public, anon, authenticated;
revoke all on function public.poll_jobs(int, int, uuid) from public, anon, authenticated;
grant execute on function public.share_account_get() to service_role;
grant execute on function public.share_account_set(uuid, text, text, bigint) to service_role;
grant execute on function public.share_claim(uuid, uuid, bigint, text) to service_role;
grant execute on function public.share_sync(uuid, bigint[]) to service_role;
grant execute on function public.poll_jobs(int, int, uuid) to service_role;
