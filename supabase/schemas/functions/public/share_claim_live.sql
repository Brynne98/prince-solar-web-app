CREATE OR REPLACE FUNCTION public.share_claim_live(p_user uuid, p_account uuid, p_plant bigint, p_plant_name text)
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
  -- account_upsert's order (link_login_live): the run, the user; then plant_users_upsert's:
  -- account, plant; billing's rows after
  perform pg_advisory_xact_lock_shared(3, 0);
  
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  perform pg_advisory_xact_lock(p_plant);
  -- read already (own login, or a live claim): no claim row without a share route. A plant
  -- gone from the user's own login (share_gone_at set) is not read: it may be claimed
  select * into mine from public.plant_users where plant_id = p_plant and user_id = p_user;
  if found and mine.share_gone_at is null then return 'yours'; end if;
  perform public.billing_links('claim_plant', jsonb_build_object('user', p_user, 'plant', p_plant, 'name', p_plant_name));

  if exists (select 1 from public.plant_users o
              where o.plant_id = p_plant and o.user_id <> p_user and o.via_share and o.share_gone_at is null) then
    raise exception 'share_claim: plant % is claimed in plant_users by another user', p_plant;
  end if;
  -- a claim that lapsed when the share was removed gives way to this one
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
