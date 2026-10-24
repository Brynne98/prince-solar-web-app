-- SOLAR-172: Remove login leaves nothing behind, so a re-added plant starts fresh.
--
-- Two things outlived Remove login and the purge:
--   * public.email_sent rows. history:538820 stopped "Your last 60 days are in" on
--     the second re-add (2026-10-24). Remove login now deletes the user's rows for
--     the plants it took away (plant_users keys on plant and user, so none of
--     them is still on their dashboard), and the login's own needs_relink rows. Done here, not in the purge,
--     so a re-add inside the purge's 2 minutes, or a plant someone else still has,
--     is covered too.
--   * the private.sunsynk_accounts row. account_disable only switched it off and a
--     re-add switched the same row back on. The row now goes, with its Vault
--     refresh-token secret (as account_disable), its login events (on delete
--     cascade, 0083), and its mark on private.inverters (nulled, as
--     api_account_delete). A login belongs to one user and plant_users rows only
--     come from it, so once this user's links are gone nothing links to it.
--
-- Body as the live api_link_disconnect (0050) otherwise: same locks, same order.

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
  sid uuid;
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

  with d as (
    delete from public.plant_users where account_id = p_account and user_id = uid returning plant_id)
  select coalesce(array_agg(plant_id order by plant_id), '{}') into gone from d;

  delete from public.email_sent e
   where e.user_id = uid
     and (e.plant_id = any (gone) or e.key like 'needs_relink:' || p_account || ':%');

  select refresh_secret_id into sid from private.sunsynk_accounts where id = p_account;
  if sid is not null then delete from vault.secrets where id = sid; end if;
  update private.inverters set account_id = null where account_id = p_account;
  delete from private.sunsynk_accounts where id = p_account;

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

-- A sync that read the login before Remove login committed must not link its
-- plants back afterwards. The guard refused a disabled row; a deleted row is
-- refused too now. Body as 0050 otherwise.
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
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and status <> 'disabled') then
    raise exception 'plant_users_upsert: account % is removed or disabled', p_account;
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
revoke all on function public.plant_users_upsert(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.plant_users_upsert(uuid, uuid, jsonb) to service_role;
