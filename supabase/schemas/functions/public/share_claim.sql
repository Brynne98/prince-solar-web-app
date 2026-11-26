CREATE OR REPLACE FUNCTION public.share_claim(p_user uuid, p_account uuid, p_plant bigint, p_plant_name text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  mine public.plant_users;
  lapsed uuid[];
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and kind = 'share' and status <> 'disabled') then
    raise exception 'share_claim: % is not the share login', p_account;
  end if;
  perform pg_advisory_xact_lock_shared(3, 0);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  perform pg_advisory_xact_lock(p_plant);
  select * into mine from public.plant_users where plant_id = p_plant and user_id = p_user;
  if found and mine.share_gone_at is null then return 'yours'; end if;
  if exists (select 1 from public.plant_users o
              where o.plant_id = p_plant and o.user_id <> p_user and (not o.via_share or o.share_gone_at is null)) then
    return 'taken';
  end if;
  with d as (delete from public.plant_users
              where plant_id = p_plant and user_id <> p_user and via_share and share_gone_at is not null
             returning user_id)
  select coalesce(array_agg(user_id), '{}') into lapsed from d;
  delete from public.email_queue where plant_id = p_plant and user_id = any (lapsed) and status = 'queued';
  perform public.plant_users_upsert(p_user, p_account,
    jsonb_build_array(jsonb_build_object('plant_id', p_plant, 'plant_name', p_plant_name)));
  update public.plant_users set via_share = true, share_missing_at = null, share_gone_at = null
   where plant_id = p_plant and user_id = p_user;
  return 'claimed';
end $function$;
