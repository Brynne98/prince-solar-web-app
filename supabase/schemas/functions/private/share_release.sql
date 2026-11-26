CREATE OR REPLACE FUNCTION private.share_release(p_account uuid, p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
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
end $function$;
