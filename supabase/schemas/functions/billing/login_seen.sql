CREATE OR REPLACE FUNCTION billing.login_seen(p_login uuid, p_plants jsonb, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  l billing.logins;
  ids bigint[];
  old_live bigint[];
  gone bigint[];
  back bigint[];
begin
  select * into l from billing.logins where id = p_login;
  if not found then return null; end if;
  perform billing.lock_account(l.account);
  ids := array(select distinct (e->>'id')::bigint from jsonb_array_elements(coalesce(p_plants, '[]')) e order by 1);
  old_live := array(select plant from billing.login_plants where login = l.id and gone_at is null order by 1);
  insert into billing.plants (id, brand, external_id)
  select x, l.brand, x::text from unnest(ids) x
  on conflict (id) do nothing;
  perform billing.lock_plants(ids || old_live);

  insert into billing.login_plants (login, plant, plant_name, last_seen_at, gone_at)
  select distinct on ((e->>'id')::bigint) l.id, (e->>'id')::bigint, e->>'name', p_at, null
    from jsonb_array_elements(coalesce(p_plants, '[]')) e
  on conflict (login, plant) do update set plant_name = coalesce(excluded.plant_name, login_plants.plant_name),
                                           last_seen_at = excluded.last_seen_at, gone_at = null, missing_since = null;
  with g as (
    update billing.login_plants set gone_at = p_at
     where login = l.id and gone_at is null and plant <> all (ids) and missing_since <= p_at - interval '50 minutes'
    returning plant)
  select coalesce(array_agg(plant order by plant), '{}') into gone from g;
  update billing.login_plants set missing_since = p_at
   where login = l.id and gone_at is null and plant <> all (ids) and missing_since is null;
  back := array(select x from unnest(ids) x where x <> all (old_live));

  if cardinality(gone) + cardinality(back) > 0 then
    -- the plants' versions move (in-flight reads stop); the account's does not, so a plant
    -- new or gone on the login never refunds a checkout in progress
    update billing.plants set version = version + 1 where id = any (gone || back);
    perform billing.log_event(l.account, p_at, 'poller', 'login_plants_seen',
                              jsonb_build_object('login', l.id, 'plants', to_jsonb(old_live)),
                              jsonb_build_object('gone', to_jsonb(gone), 'new', to_jsonb(back)));
  end if;
  return jsonb_build_object('gone', to_jsonb(gone), 'new', to_jsonb(back));
end $function$;
