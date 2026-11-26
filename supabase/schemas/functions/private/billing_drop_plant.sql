CREATE OR REPLACE FUNCTION private.billing_drop_plant(p_user uuid, p_plant bigint)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'vault', 'pg_temp'
AS $function$
declare acc uuid; sid uuid;
begin
  if billing.is_live() then return; end if;
  select account_id into acc from public.plant_users where user_id = p_user and plant_id = p_plant;
  if acc is not null then perform pg_advisory_xact_lock(1, hashtext(acc::text)); end if;
  perform pg_advisory_xact_lock(p_plant);
  delete from public.plant_users where user_id = p_user and plant_id = p_plant;
  delete from public.email_queue where user_id = p_user and plant_id = p_plant and kind not like 'sunsynk_%';
  if not exists (select 1 from public.plant_users where plant_id = p_plant) then
    perform private.plants_tombstone(array[p_plant]);
  end if;
  if acc is not null and not exists (select 1 from public.plant_users where account_id = acc) then
    delete from public.email_queue where user_id = p_user and key like 'needs_relink:' || acc || ':%';
    select refresh_secret_id into sid from private.sunsynk_accounts where id = acc;
    if sid is not null then delete from vault.secrets where id = sid; end if;
    update private.inverters set account_id = null where account_id = acc;
    delete from private.sunsynk_accounts where id = acc;
  end if;
end $function$;
