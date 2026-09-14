-- ============================================================================
-- 0050 — Remove wipes the plant.
--
-- When a dashboard user removes a SunSynk login (Settings → Logins), every plant
-- that login exposed and that no OTHER dashboard user still shares loses all its
-- rows, so a later relink behaves exactly like a first link: config seeded with
-- the 60-day bookmarks, bootstrap kick, "Fetching history" pill. A second login
-- of the same user does not count as sharing; its next hourly sync reseeds the
-- plant as fresh. Deleting an account takes the same path.
--
--   * private.plant_purge — one tombstone per plant waiting to be wiped. Remove
--     and account-delete only queue; the wipe itself runs out of band because the
--     biggest plant today is ~850k rows across the ten tables and `authenticated`
--     has an 8 s statement timeout.
--   * private.purge_plant(plant) — the wipe, one plant, in the caller's
--     transaction, under the plant's advisory lock. private.purge_plants() is
--     the pg_cron worker (every 5 min, one transaction per plant). The link
--     path drains its own tombstones: plant_users_upsert wipes any queued plant
--     it is about to record, in the same transaction, before the link row goes
--     in, so the restored read policies (0049) never show old rows and
--     plant_config_seed's `on conflict do nothing` finds no row.
--   * A BEFORE INSERT trigger on every per-plant table drops rows for a plant
--     that has no plant_users row. That is the writer guard: an in-flight poll
--     or recover cannot resurrect a wiped plant, and the guard sits where every
--     writer meets (poll_commit, q_insert_recovered, q_insert_inverter_history,
--     the plant_energy and grid_burst upserts, inverters_seed, meta_upsert)
--     rather than in each of them. Rows with a null plant_id pass as before.
--   * Locks. Every plant has an advisory lock keyed by its id; every SunSynk
--     account one keyed (1, hashtext(id)). Remove, account-delete and
--     plant_users_upsert take the account lock(s) first, then the plants in
--     ascending order, so the hourly sync of a login cannot add a plant while
--     that login is being removed, and no two of them can deadlock.
--   * plant_users_upsert refuses a disabled account.
--   * api_link_disconnect now returns jsonb {plantsRemoved, queued}.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tombstones
-- ---------------------------------------------------------------------------
create table if not exists private.plant_purge (
  plant_id     bigint primary key,
  requested_at timestamptz not null default now()
);
comment on table private.plant_purge is
  'Plants whose last dashboard user removed them; purge_plants() deletes every row for each and then the tombstone.';

-- Queue plants for the wipe. Also unpins the single-site calibration plant if it
-- is one of them (0041 pins it forever otherwise), so the next link takes over.
create or replace function private.plants_tombstone(p_plants bigint[])
returns void
language sql
set search_path = public, private, pg_temp
as $$
  insert into private.plant_purge (plant_id)
  select distinct p from unnest(p_plants) p
  on conflict (plant_id) do nothing;
  delete from public.app_config
   where key = 'CALIBRATION_PLANT' and value = any (p_plants::double precision[]);
$$;

-- ---------------------------------------------------------------------------
-- 2. The wipe
-- ---------------------------------------------------------------------------
-- One plant, in the caller's transaction, under the plant's advisory lock (the
-- same lock api_link_disconnect and api_account_delete take before deciding a
-- plant is orphaned). Null when there was no tombstone, or when p_wait is false
-- and someone else holds the plant (an overlapping cron run: the tombstone stays
-- for the next one). A plant that has a plant_users row again is live: keep its
-- data, drop the tombstone, say so.
create or replace function private.purge_plant(p_plant bigint, p_wait boolean default true)
returns jsonb
language plpgsql
set search_path = public, private, pg_temp
as $$
declare
  out jsonb := '{}'::jsonb;
  n bigint;
begin
  if p_wait then
    perform pg_advisory_xact_lock(p_plant);
  elsif not pg_try_advisory_xact_lock(p_plant) then
    return null;
  end if;
  if not exists (select 1 from private.plant_purge where plant_id = p_plant) then
    return null;
  end if;
  if exists (select 1 from public.plant_users where plant_id = p_plant) then
    delete from private.plant_purge where plant_id = p_plant;
    return jsonb_build_object('skipped', 'linked again');
  end if;

  delete from public.readings         where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings', n);
  delete from public.strings          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings', n);
  delete from public.agg_minute       where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_minute', n);
  delete from public.plant_energy     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_energy', n);
  delete from public.inverter_history where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history', n);
  delete from public.grid_burst       where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('grid_burst', n);
  delete from public.plant_config     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from private.gaps            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('gaps', n);
  delete from private.meta            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters       where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  delete from private.plant_purge     where plant_id = p_plant;
  return out;
end $$;

-- The cron worker: every pending tombstone, one transaction each, so a big plant
-- never holds the others and a failure leaves the rest for the next run.
-- (No SET clause: a procedure with one may not COMMIT. Everything is qualified.)
create or replace procedure private.purge_plants()
language plpgsql
as $$
declare
  ids bigint[];
  p bigint;
  r jsonb;
begin
  select coalesce(array_agg(plant_id order by requested_at, plant_id), '{}') into ids from private.plant_purge;
  foreach p in array ids loop
    begin
      r := private.purge_plant(p, false);
    exception when others then
      -- the plant stays tombstoned for the next run; the others still get done
      raise warning 'purge of plant % failed: %', p, sqlerrm;
      r := null;
    end;
    commit;
    if r is not null then raise notice 'purged plant %: %', p, r; end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Writer guard: no plant_users row, no rows
-- ---------------------------------------------------------------------------
-- The shared advisory lock is what makes this airtight: a writer holds it until
-- it commits, so Remove (exclusive) waits for an in-flight poll before deciding,
-- and a writer that arrives while Remove or the wipe holds the plant is dropped
-- instead of waiting (try-lock: never blocks, so it can never deadlock). The
-- one-minute loss on a shared plant during another user's Remove is refilled by
-- recover.
create or replace function private.plant_row_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.plant_id is null then return new; end if;
  if pg_try_advisory_xact_lock_shared(new.plant_id)
     and exists (select 1 from public.plant_users pu where pu.plant_id = new.plant_id) then
    return new;
  end if;
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'public.readings', 'public.strings', 'public.agg_minute', 'public.plant_energy',
    'public.plant_config', 'public.inverter_history', 'public.grid_burst',
    'private.gaps', 'private.meta', 'private.inverters'
  ] loop
    execute format('drop trigger if exists plant_row_guard on %s', t);
    execute format('create trigger plant_row_guard before insert on %s for each row execute function private.plant_row_guard()', t);
  end loop;
end $$;

-- plant_users_upsert: 0041's body, under the account and plant locks. Refuses a
-- disabled account (an in-flight hourly sync of the login just removed), and
-- wipes any plant in the list that is waiting to be purged BEFORE recording the
-- link, in this transaction, so a relink starts from an empty plant.
create or replace function public.plant_users_upsert(p_user uuid, p_account uuid, p_rows jsonb)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare p bigint;
begin
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  for p in select distinct (r->>'plant_id')::bigint from jsonb_array_elements(p_rows) r order by 1 loop
    perform pg_advisory_xact_lock(p);
  end loop;
  if exists (select 1 from private.sunsynk_accounts where id = p_account and status = 'disabled') then
    raise exception 'plant_users_upsert: account % is disabled', p_account;
  end if;
  for p in
    select g.plant_id from private.plant_purge g
     where g.plant_id in (select (r->>'plant_id')::bigint from jsonb_array_elements(p_rows) r)
     order by g.plant_id
  loop
    raise notice 'plant % relinked while waiting to be purged: wiping first (%)', p, private.purge_plant(p);
  end loop;

  insert into public.plant_users (plant_id, user_id, account_id, plant_name)
  select (r->>'plant_id')::bigint, p_user, p_account, r->>'plant_name'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id, user_id) do update
    set account_id = excluded.account_id, plant_name = excluded.plant_name;

  insert into public.app_config (key, value, note)
  select 'CALIBRATION_PLANT', (r->>'plant_id')::bigint,
         'the one plant the single-site forecast/alerts are bound to; set by the first link, then fixed'
    from jsonb_array_elements(p_rows) r
   order by (r->>'plant_id')::bigint
   limit 1
  on conflict (key) do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Remove a login
-- ---------------------------------------------------------------------------
-- Lock every plant the link exposes, drop the link rows, and tombstone each plant
-- no other dashboard user still has. The account row stays (disabled, tokens
-- gone): plant_users.account_id is `on delete set null`, so deleting it would
-- stop other users' polling of a shared plant.
drop function if exists public.api_link_disconnect(uuid);
create or replace function public.api_link_disconnect(p_account uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, vault, pg_temp
as $$
declare
  uid uuid := auth.uid();
  p bigint;
  mine bigint[];
  gone bigint[];
  orphans bigint[];
begin
  if uid is null or not exists (select 1 from private.sunsynk_accounts where id = p_account and user_id = uid) then
    raise exception 'not your account';
  end if;

  -- account lock, then its plants ascending: the order every path uses. Holding
  -- the account lock means its hourly sync cannot add a plant under us.
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  select coalesce(array_agg(plant_id order by plant_id), '{}') into mine
    from public.plant_users where account_id = p_account and user_id = uid;
  foreach p in array mine loop perform pg_advisory_xact_lock(p); end loop;
  perform public.account_disable(p_account);

  with d as (
    delete from public.plant_users where account_id = p_account and user_id = uid returning plant_id)
  select coalesce(array_agg(plant_id order by plant_id), '{}') into gone from d;

  select coalesce(array_agg(g order by g), '{}') into orphans
    from unnest(gone) g
   where not exists (select 1 from public.plant_users o where o.plant_id = g and o.user_id <> uid);
  perform private.plants_tombstone(orphans);

  return jsonb_build_object(
    'plantsRemoved', coalesce(array_length(gone, 1), 0),
    'queued',        coalesce(array_length(orphans, 1), 0));
end $$;
revoke all on function public.api_link_disconnect(uuid) from public, anon;
grant execute on function public.api_link_disconnect(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Delete my account: the same path
-- ---------------------------------------------------------------------------
-- 0028's body, with the orphan plants captured under lock before the accounts
-- go and handed to the same tombstone queue (0028 deleted inline and missed
-- inverter_history and grid_burst).
create or replace function public.api_account_delete()
returns jsonb
language plpgsql
security definer
set search_path = public, private, vault, pg_temp
as $$
declare
  uid uuid := auth.uid();
  acc record;
  p bigint;
  mine bigint[];
  orphans bigint[];
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;

  for acc in select id from private.sunsynk_accounts where user_id = uid order by id loop
    perform pg_advisory_xact_lock(1, hashtext(acc.id::text));
  end loop;
  select coalesce(array_agg(plant_id order by plant_id), '{}') into mine
    from public.plant_users where user_id = uid;
  foreach p in array mine loop perform pg_advisory_xact_lock(p); end loop;
  select coalesce(array_agg(g order by g), '{}') into orphans
    from unnest(mine) g
   where not exists (select 1 from public.plant_users o where o.plant_id = g and o.user_id <> uid);

  for acc in select id, refresh_secret_id from private.sunsynk_accounts where user_id = uid loop
    if acc.refresh_secret_id is not null then delete from vault.secrets where id = acc.refresh_secret_id; end if;
    update private.inverters set account_id = null where account_id = acc.id;
  end loop;
  delete from private.sunsynk_accounts where user_id = uid;

  delete from public.plant_users where user_id = uid;
  perform private.plants_tombstone(orphans);

  delete from public.profiles where user_id = uid;
  delete from auth.users where id = uid;
  return jsonb_build_object('deleted', true, 'plantsRemoved', coalesce(array_length(orphans, 1), 0));
end $$;
revoke all on function public.api_account_delete() from public, anon;
grant execute on function public.api_account_delete() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Schedule (production only, as 0009: no-op where pg_cron is absent)
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping plant-purge schedule (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'plant-purge') then
    perform cron.unschedule('plant-purge');
  end if;
  perform cron.schedule('plant-purge', '*/5 * * * *', 'call private.purge_plants()');
end $$;
