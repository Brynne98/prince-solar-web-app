CREATE OR REPLACE FUNCTION public.api_link_disconnect(p_account uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'vault', 'pg_temp'
AS $function$
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
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (0170)
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  select coalesce(array_agg(plant_id order by plant_id), '{}') into mine
    from public.plant_users where account_id = p_account and user_id = uid;
  foreach p in array mine loop perform pg_advisory_xact_lock(p); end loop;

  with d as (
    delete from public.plant_users where account_id = p_account and user_id = uid returning plant_id)
  select coalesce(array_agg(plant_id order by plant_id), '{}') into gone from d;

  delete from public.email_queue e
   where e.user_id = uid
     and ((e.plant_id = any (gone) and e.kind not like 'sunsynk_%') or e.key like 'needs_relink:' || p_account || ':%');

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
end $function$;
