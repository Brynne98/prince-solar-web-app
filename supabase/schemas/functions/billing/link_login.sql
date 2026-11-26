CREATE OR REPLACE FUNCTION billing.link_login(p_account uuid, p_brand text, p_username text, p_secret_ref uuid, p_plants jsonb, p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text, p_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  a billing.accounts;
  st billing.status;
  l billing.logins;
  ids bigint[];
  old_ids bigint[] := '{}';
  old_live bigint[] := '{}';
  changed bigint[];
  is_new boolean;
begin
  a := billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  -- the same login whatever the case of its email (SunSynk ignores it)
  select * into l from billing.logins where account = p_account and brand = p_brand and lower(username) = lower(p_username);
  is_new := l.id is null;

  if is_new then
    if st.state = 'ended' then
      raise exception 'no login can be added without a plan' using errcode = '22023';
    end if;
    if st.state in ('none', 'trialing') and exists (select 1 from billing.logins where account = p_account) then
      raise exception 'one login during the free week' using errcode = '22023';
    end if;
  else
    old_ids := array(select plant from billing.login_plants where login = l.id);
    old_live := array(select plant from billing.login_plants where login = l.id and gone_at is null);
  end if;

  ids := array(select distinct (e->>'id')::bigint from jsonb_array_elements(coalesce(p_plants, '[]')) e order by 1);
  insert into billing.plants (id, brand, external_id)
  select x, p_brand, x::text from unnest(ids) x
  on conflict (id) do nothing;
  perform billing.lock_plants(ids || old_ids);

  if is_new then
    insert into billing.logins (id, account, brand, username, secret_ref, status, created_at)
    values (coalesce(p_id, gen_random_uuid()), p_account, p_brand, p_username, p_secret_ref, 'ok', p_at) returning * into l;
  else
    update billing.logins set secret_ref = coalesce(p_secret_ref, secret_ref), status = 'ok' where id = l.id;
  end if;

  insert into billing.login_plants (login, plant, plant_name, last_seen_at, gone_at)
  select distinct on ((e->>'id')::bigint) l.id, (e->>'id')::bigint, e->>'name', p_at, null
    from jsonb_array_elements(coalesce(p_plants, '[]')) e
  on conflict (login, plant) do update set plant_name = coalesce(excluded.plant_name, login_plants.plant_name),
                                           last_seen_at = excluded.last_seen_at, gone_at = null;
  update billing.login_plants set gone_at = p_at
   where login = l.id and gone_at is null and plant <> all (ids);
  changed := array(select x from unnest(ids) x where x <> all (old_live)
                   union select x from unnest(old_live) x where x <> all (ids));
  update billing.plants set version = version + 1 where id = any (changed);

  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, case when is_new then 'link_login' else 'relink_login' end,
                            jsonb_build_object('state', st.state, 'plants', to_jsonb(old_ids)),
                            jsonb_build_object('login', l.id, 'plants', to_jsonb(ids)));
  return billing.account_state(p_account, p_at);
end $function$;
