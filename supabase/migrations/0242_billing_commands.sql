-- ============================================================================
-- 0242 — billing redesign phase 1: the plant and login commands (SOLAR-641).
--
-- All writes go through commands. Each one locks the account row, then the plants
-- it touches in id order, checks the state from billing.account_status at `at`,
-- writes, bumps accounts.version and logs one account_events row. Each returns
-- billing.account_state after the change.
--
-- set_chosen_plants(account, plants, at): the full list of chosen plants.
--   none -> trialing in one step (trial_started_at, trial_ends_at).
--   trialing/none: at most market.trial_places, and no plant whose week was used
--   by another account. active: at most places. past_due and ended: refused.
--   Plants must be on one of the account's logins or claimed by it.
--   Every newly seated plant, on any state, is marked as having used its week
--   (trial_used_at; trial_used_by when empty), so a plant once paid for cannot
--   give a later account a free week.
-- link_login(account, brand, username, secret_ref, plants, at): adds a login or
--   reconnects one already there. None added while ended; one in none/trialing.
--   Plants missing from the new list get gone_at. Never starts the week.
--   Plants whose route changed (gone, back, or new on this login) get a
--   version bump, so in-flight reads see the change.
-- remove_login(account, login, at): closes a seat only when the account loses its
--   last route to that plant. Returns the plants no account protects any more
--   ('unprotected'); the delete job (later phase) removes their history.
-- ============================================================================

create function billing.log_event(p_account uuid, p_at timestamptz, p_actor text, p_kind text,
                                  p_before jsonb, p_after jsonb, p_reason text default null)
returns void language sql set search_path = billing, pg_temp as $$
  insert into billing.account_events (account, at, actor, kind, before, after, reason)
  values (p_account, p_at, p_actor, p_kind, p_before, p_after, p_reason)
$$;

-- Locks the account row; raises when there is none.
create function billing.lock_account(p_account uuid)
returns billing.accounts language plpgsql set search_path = billing, pg_temp as $$
declare a billing.accounts;
begin
  select * into a from billing.accounts where id = p_account for update;
  if not found then raise exception 'no such account' using errcode = 'P0002'; end if;
  return a;
end $$;

create function billing.lock_plants(p_plants bigint[])
returns void language sql set search_path = billing, pg_temp as $$
  select null from (select id from billing.plants where id = any (p_plants) order by id for update) x
$$;

-- Makes `want` the account's open seats: closes the rest, opens the new ones, marks
-- each newly seated plant's week as used and bumps the version of every plant that
-- changed. The caller holds the account and plant locks and has checked the rules.
create function billing.write_seats(p_account uuid, p_want bigint[], p_at timestamptz, p_reason text default 'switched')
returns void language plpgsql set search_path = billing, pg_temp as $$
declare had bigint[];
begin
  had := array(select plant from billing.seats where account = p_account and closed_at is null order by 1);
  update billing.seats set closed_at = p_at, close_reason = p_reason
   where account = p_account and closed_at is null and plant <> all (p_want);
  insert into billing.seats (account, plant, chosen_at)
  select p_account, x, p_at from unnest(p_want) x where x <> all (had);
  update billing.plants set trial_used_at = coalesce(trial_used_at, p_at),
                            trial_used_by = coalesce(trial_used_by, p_account)
   where id = any (p_want) and id <> all (had) and (trial_used_at is null or trial_used_by is null);
  update billing.plants set version = version + 1
   where id = any (p_want || had) and not (id = any (p_want) and id = any (had));
end $$;

-- ---------------------------------------------------------------------------
create function billing.set_chosen_plants(p_account uuid, p_plants bigint[],
                                          p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  a billing.accounts;
  m billing.markets;
  st billing.status;
  want bigint[];
  had bigint[];
  bad bigint;
begin
  a := billing.lock_account(p_account);
  select * into m from billing.markets where code = a.market;
  want := array(select distinct x from unnest(coalesce(p_plants, '{}')) x order by 1);
  had := array(select plant from billing.seats where account = p_account and closed_at is null order by 1);
  perform billing.lock_plants(want || had);
  st := billing.account_status(p_account, p_at);

  if st.state not in ('none', 'trialing', 'active') then
    raise exception 'plants cannot be chosen while the account is %', st.state using errcode = '22023';
  end if;
  select x into bad from unnest(want) x where not billing.has_route(p_account, x, false) limit 1;
  if found then
    raise exception 'plant % is not on this account''s logins', bad using errcode = '22023';
  end if;

  if st.state in ('none', 'trialing') then
    if cardinality(want) = 0 and st.state = 'none' then
      raise exception 'choose at least one plant to start the free week' using errcode = '22023';
    end if;
    select x into bad from unnest(want) x join billing.plants p on p.id = x
     where p.trial_used_at is not null and p.trial_used_by is distinct from p_account limit 1;
    if found then
      raise exception 'plant % already had its free week', bad using errcode = '22023';
    end if;
    if cardinality(want) > m.trial_places then
      raise exception 'the free week reads up to % plants', m.trial_places using errcode = '22023';
    end if;
    if st.state = 'none' then
      update billing.accounts set trial_started_at = p_at, trial_ends_at = p_at + make_interval(days => m.trial_days)
       where id = p_account;
    end if;
  elsif cardinality(want) > st.places then
    raise exception 'your plan has % places', st.places using errcode = '22023';
  end if;

  perform billing.write_seats(p_account, want, p_at);
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'set_chosen_plants',
                            jsonb_build_object('state', st.state, 'plants', to_jsonb(had)),
                            jsonb_build_object('plants', to_jsonb(want)));
  return billing.account_state(p_account, p_at);
end $$;

-- ---------------------------------------------------------------------------
-- p_plants: [{"id": 123, "name": "Home"}, ...], the login's whole list right now.
create function billing.link_login(p_account uuid, p_brand text, p_username text, p_secret_ref uuid,
                                   p_plants jsonb, p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
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
  select * into l from billing.logins where account = p_account and brand = p_brand and username = p_username;
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
    insert into billing.logins (account, brand, username, secret_ref, status, created_at)
    values (p_account, p_brand, p_username, p_secret_ref, 'ok', p_at) returning * into l;
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
end $$;

-- ---------------------------------------------------------------------------
create function billing.remove_login(p_account uuid, p_login uuid,
                                     p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  st billing.status;
  reached bigint[];
  closed bigint[];
  unprotected bigint[];
begin
  perform billing.lock_account(p_account);
  if not exists (select 1 from billing.logins where id = p_login and account = p_account) then
    raise exception 'no such login on this account' using errcode = 'P0002';
  end if;
  st := billing.account_status(p_account, p_at);
  reached := array(select plant from billing.login_plants where login = p_login order by 1);
  perform billing.lock_plants(reached);

  delete from billing.logins where id = p_login;
  with c as (
    update billing.seats set closed_at = p_at, close_reason = 'login_removed'
     where account = p_account and closed_at is null and plant = any (reached)
       and not billing.has_route(p_account, plant, false)
    returning plant)
  select coalesce(array_agg(plant order by plant), '{}') into closed from c;
  update billing.plants set version = version + 1 where id = any (closed);

  unprotected := array(select x from unnest(closed) x
                        where not (billing.plant_state(x, p_at)->>'protected')::boolean);
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'remove_login',
                            jsonb_build_object('state', st.state, 'login', p_login, 'plants', to_jsonb(reached)),
                            jsonb_build_object('closed', to_jsonb(closed), 'unprotected', to_jsonb(unprotected)));
  return billing.account_state(p_account, p_at) || jsonb_build_object('unprotected', to_jsonb(unprotected));
end $$;

revoke all on function billing.log_event(uuid, timestamptz, text, text, jsonb, jsonb, text) from public, anon, authenticated;
revoke all on function billing.lock_account(uuid) from public, anon, authenticated;
revoke all on function billing.lock_plants(bigint[]) from public, anon, authenticated;
revoke all on function billing.write_seats(uuid, bigint[], timestamptz, text) from public, anon, authenticated;
revoke all on function billing.set_chosen_plants(uuid, bigint[], timestamptz, text) from public, anon, authenticated;
revoke all on function billing.link_login(uuid, text, text, uuid, jsonb, timestamptz, text) from public, anon, authenticated;
revoke all on function billing.remove_login(uuid, uuid, timestamptz, text) from public, anon, authenticated;
grant execute on function billing.set_chosen_plants(uuid, bigint[], timestamptz, text) to service_role;
grant execute on function billing.link_login(uuid, text, text, uuid, jsonb, timestamptz, text) to service_role;
grant execute on function billing.remove_login(uuid, uuid, timestamptz, text) to service_role;
