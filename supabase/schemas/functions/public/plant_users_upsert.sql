CREATE OR REPLACE FUNCTION public.plant_users_upsert(p_user uuid, p_account uuid, p_rows jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  p bigint;
  ids bigint[] := array(select (r->>'plant_id')::bigint from jsonb_array_elements(p_rows) r);
  login boolean;
  who text;
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  for p in select distinct x from unnest(ids) x order by 1 loop
    perform pg_advisory_xact_lock(p);
  end loop;
  select kind = 'login', sunsynk_username into login, who from private.sunsynk_accounts where id = p_account and status <> 'disabled';
  if not found then
    raise exception 'plant_users_upsert: account % is removed or disabled', p_account;
  end if;
  insert into public.plant_users (plant_id, user_id, account_id, plant_name)
  select (r->>'plant_id')::bigint, p_user, p_account, r->>'plant_name'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id, user_id) do update
    set account_id = excluded.account_id, plant_name = excluded.plant_name;
  if login and cardinality(ids) > 0 then
    update public.plant_users set share_missing_at = null, share_gone_at = null
     where account_id = p_account and user_id = p_user and not via_share and plant_id = any (ids)
       and (share_missing_at is not null or share_gone_at is not null);
    with g as (
      update public.plant_users set share_gone_at = now()
       where account_id = p_account and user_id = p_user and not via_share and share_gone_at is null
         and share_missing_at < now() - interval '50 minutes' and plant_id <> all (ids)
      returning user_id, plant_id, plant_name)
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    select g.user_id, g.plant_id, 'plant_off_login', 'plant_off_login:' || g.plant_id || ':' || extract(epoch from now())::bigint,
           jsonb_build_object('plants', jsonb_build_array(coalesce(g.plant_name, 'Plant ' || g.plant_id)), 'login', who), 1
      from g
    on conflict do nothing;
    update public.plant_users set share_missing_at = now()
     where account_id = p_account and user_id = p_user and not via_share and share_gone_at is null
       and share_missing_at is null and plant_id <> all (ids);
  end if;
  insert into public.app_config (key, value, note)
  select 'CALIBRATION_PLANT', (r->>'plant_id')::bigint,
         'the one plant the single-site forecast/alerts are bound to; set by the first link, then fixed'
    from jsonb_array_elements(p_rows) r order by (r->>'plant_id')::bigint limit 1
  on conflict (key) do nothing;
end $function$;
