-- ============================================================================
-- 0273 — billing lock order (SOLAR-642). Every writer below takes its locks in one order:
--   billing-run lock (3,0) shared, login locks (1, hashtext(login id)) in id order, plant
--   locks (plant id) in id order, link rows (plant_users), billing accounts in id order,
--   billing plants in id order, then the rows it writes.
-- Before this, 4 pairs took them the other way round and Postgres cancelled one (40P01):
--   1. reconnect (link_login_live, account_upsert) took no login lock: vs api_account_delete
--   2. a login's status change locked its plants with no account lock, copy by copy:
--      vs set_chosen_plants / login_seen
--   3. poll_commit_v2 locked plants, then login rows (its own, and other logins it marks
--      read): vs api_link_remove and link_login_live. Two polls on a plant whose history
--      was deleted both held it for share, then both updated it.
--   4. share_sync locked accounts in RETURNING order: vs billing.run (account order)
-- Races: scripts/billing-lock-order-test.mjs.
-- ============================================================================

-- The logins' locks in id order. p_status: the status the caller is about to write
-- (null: none). Logins whose status changes fire login_status_follow, which writes their
-- billing login and plants, so their accounts and plants are locked here first, before any
-- login row: copy by copy, the trigger would take them in row order. p_user's account and
-- p_plants are locked with them.
create function private.login_lock(p_logins uuid[], p_status text, p_user uuid default null,
                                   p_plants bigint[] default '{}')
returns void language plpgsql security definer set search_path = pg_temp as $$
declare
  x uuid;
  moving uuid[];
begin
  foreach x in array array(select distinct l from unnest(p_logins) l where l is not null order by 1) loop
    perform pg_advisory_xact_lock(1, hashtext(x::text));
  end loop;
  moving := case when p_status is null then '{}'::uuid[]
                 else array(select sa.id from private.sunsynk_accounts sa
                             where sa.id = any (p_logins) and sa.status is distinct from p_status) end;
  perform 1 from billing.accounts a
   where a.id in (select bl.account from billing.logins bl where bl.id = any (moving))
      or a.user_id = p_user
   order by a.id for update;
  perform billing.lock_plants(array(select lp.plant from billing.login_plants lp where lp.login = any (moving))
                              || coalesce(p_plants, '{}'));
end $$;
revoke all on function private.login_lock(uuid[], text, uuid, bigint[]) from public, anon, authenticated;

-- The stored logins a link of this username touches: the user's own (any status) and every
-- live copy (login_copies' match).
create function private.username_logins(p_user uuid, p_username text)
returns uuid[] language sql stable security definer set search_path = pg_temp as $$
  select coalesce(array_agg(sa.id order by sa.id), '{}') from private.sunsynk_accounts sa
   where lower(sa.sunsynk_username) = lower(p_username)
     and ((sa.user_id = p_user and sa.kind = 'login') or sa.status <> 'disabled')
$$;
revoke all on function private.username_logins(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Pair 2. The trigger reads first, then the account, then the plants in id order, then writes.
-- Its callers below have locked all of it already; this keeps any other status writer in order.
-- ---------------------------------------------------------------------------
create or replace function billing.login_status_follow()
returns trigger language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  want text := case new.status when 'active' then 'ok' when 'needs_relink' then 'needs_reconnect' end;
  l billing.logins;
begin
  -- 'disabled' (disconnected in the old screens) is not a broken login: remove_login handles it
  if want is null then return null; end if;
  select * into l from billing.logins where id = new.id;
  if l.id is null or l.status = want then return null; end if;
  perform billing.lock_account(l.account);
  perform billing.lock_plants(array(select plant from billing.login_plants where login = l.id));
  update billing.logins set status = want where id = l.id and status <> want returning * into l;
  if l.id is not null then
    update billing.plants set version = version + 1
     where id in (select plant from billing.login_plants where login = l.id);
    perform billing.log_event(l.account, now(), 'poller', 'login_status',
                              jsonb_build_object('login', l.id, 'status', old.status),
                              jsonb_build_object('login', l.id, 'status', want));
  end if;
  return null;
end $$;

-- 0246's account_mark: the login and every copy, their accounts and plants, before the rows.
create or replace function public.account_mark(p_account uuid, p_status text, p_error text)
returns void language plpgsql security definer set search_path = private, pg_temp as $$
begin
  -- the copies' status moves only with a dead sign-in
  perform private.login_lock(array(select p_account union select private.login_copies(p_account)
                                    where p_status = 'needs_relink'), p_status);
  -- One row for the account poll was working on; its copies die with it below.
  insert into private.sunsynk_login_events (account_id, event, reason, last_ok_at, access_expires_at)
  select id, 'died', p_error, last_ok_at, access_expires_at
    from private.sunsynk_accounts
   where id = p_account and p_status = 'needs_relink';
  update private.sunsynk_accounts set status = p_status, last_error = p_error where id = p_account;
  -- A dead sign-in is dead for every copy holding that same refresh token. A copy
  -- with a different (newer) token, or a row with none, keeps its own status, and
  -- other errors stay with the row.
  update private.sunsynk_accounts set status = p_status, last_error = p_error
   where p_status = 'needs_relink' and id in (select private.login_copies(p_account))
     and public.account_refresh_get(id) = public.account_refresh_get(p_account);
end $$;

-- 0063's account_access_set: its copies turn active, so their accounts and plants first.
create or replace function public.account_access_set(p_account uuid, p_access text, p_expires bigint)
returns void language plpgsql security definer set search_path = private, pg_temp as $$
begin
  perform private.login_lock(array(select p_account union select private.login_copies(p_account)), 'active');
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires, last_ok_at = now(), last_error = null
   where id = p_account;
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires, status = 'active', last_error = null
   where id in (select private.login_copies(p_account));
end $$;

-- 0063's account_refresh_set: the login locks before the copies' rows (no status change).
create or replace function public.account_refresh_set(p_account uuid, p_refresh text)
returns void language plpgsql security definer set search_path = private, vault, pg_temp as $$
declare c uuid;
begin
  perform private.login_lock(array(select p_account union select private.login_copies(p_account)), null);
  perform private.refresh_store(p_account, p_refresh);
  for c in select private.login_copies(p_account) loop
    perform private.refresh_store(c, p_refresh);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Pair 1. 0252's account_upsert: the login locks of this username's logins, then the user's
-- account and the accounts and plants the status change reaches, before any row. The
-- user's account also comes before the new login row, whose user key a delete waits on.
-- ---------------------------------------------------------------------------
create or replace function public.account_upsert(p_user uuid, p_username text, p_access text, p_expires bigint)
returns uuid language plpgsql security definer set search_path = private, pg_temp as $$
declare acc uuid;
begin
  -- plant_users_upsert's order (0170), so two links at once queue here and the second sees the first's login
  perform pg_advisory_xact_lock_shared(3, 0);
  perform private.login_lock(private.username_logins(p_user, p_username), 'active', p_user);
  -- read under the locks: a delete or another link may have finished while this waited
  if not public.link_login_allowed(p_user, p_username) then
    raise exception 'one login' using errcode = '22023';
  end if;
  -- the same login whatever the case of its email (SunSynk ignores it): the row already
  -- stored is updated in place; a new one only when there is none
  select id into acc from private.sunsynk_accounts
   where user_id = p_user and kind = 'login' and lower(sunsynk_username) = lower(p_username)
   order by sunsynk_username = p_username desc, id limit 1;
  -- Before the update below wipes status and last_error. A first link has no row.
  insert into private.sunsynk_login_events (account_id, event, reason, last_ok_at, access_expires_at)
  select id, 'relinked', status || coalesce(': ' || last_error, ''), last_ok_at, access_expires_at
    from private.sunsynk_accounts where id = acc;
  if acc is null then
    insert into private.sunsynk_accounts (user_id, sunsynk_username, access_token, access_expires_at, status, last_ok_at, last_error)
    values (p_user, p_username, p_access, p_expires, 'active', now(), null)
    returning id into acc;
  else
    update private.sunsynk_accounts
       set access_token = p_access, access_expires_at = p_expires, status = 'active', last_ok_at = now(), last_error = null
     where id = acc;
  end if;
  -- A fresh sign-in replaces whatever the other copies held. The refresh token
  -- follows in account_refresh_set, which link-sunsynk calls next.
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires, status = 'active', last_error = null
   where id in (select private.login_copies(acc));
  return acc;
end $$;

-- 0247's link_login_live: billing.link_login locks the incoming plants and the login's old
-- ones in one sorted call after the status change has locked some, so all of them first.
create or replace function public.link_login_live(p_user uuid, p_username text, p_access text, p_expires bigint,
                                                  p_refresh text, p_plants jsonb)
returns uuid language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  acc uuid;
  mine uuid[];
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  mine := private.username_logins(p_user, p_username);
  perform private.login_lock(mine, 'active', p_user,
    array(select (e->>'id')::bigint from jsonb_array_elements(coalesce(p_plants, '[]'::jsonb)) e where e->>'id' is not null
          union
          select lp.plant from billing.login_plants lp join billing.logins bl on bl.id = lp.login
           join billing.accounts ba on ba.id = bl.account
           where ba.user_id = p_user and bl.id = any (mine)));
  acc := public.account_upsert(p_user, p_username, p_access, p_expires);
  perform public.account_refresh_set(acc, p_refresh);
  perform public.billing_links('link_login', jsonb_build_object('user', p_user, 'login', acc, 'username', p_username,
                                                                 'plants', coalesce(p_plants, '[]'::jsonb)));
  return acc;
end $$;

-- ---------------------------------------------------------------------------
-- Pair 3. 0246's poll_commit_v2: the login lock first, then the plants in id order; a plant
-- whose history was deleted is updated below, so it is taken for no key update now, not
-- for share then upgraded (two polls holding it for share would deadlock there).
-- ---------------------------------------------------------------------------
create or replace function public.poll_commit_v2(
  p_versions  jsonb,
  p_account   uuid,
  p_ts        bigint,
  p_readings  jsonb,
  p_strings   jsonb,
  p_agg       jsonb,
  p_meta      jsonb,
  p_inverters jsonb,
  p_access    text,
  p_expires   bigint,
  p_at        timestamptz default now()
)
returns jsonb language plpgsql security definer set search_path = pg_temp as $$
declare
  ok bigint[];
  out jsonb;
  pl record;
begin
  if not billing.is_live() then
    return public.poll_commit(p_account, p_ts, p_readings, p_strings, p_agg, p_meta, p_inverters, p_access, p_expires);
  end if;
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  for pl in select bp.id, bp.history_purged_at is not null as purged from billing.plants bp
             where bp.id in (select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k)
             order by bp.id loop
    if pl.purged then
      perform 1 from billing.plants where id = pl.id for no key update;
    else
      perform 1 from billing.plants where id = pl.id for share;
    end if;
  end loop;
  ok := billing.write_allowed(p_versions, p_at);
  -- the token is saved whatever happens to the readings: the fetch may have refreshed it
  perform set_config('billing.guarded', 'on', true);
  out := public.poll_commit(p_account, p_ts, billing.only_plants(p_readings, ok), billing.only_plants(p_strings, ok),
                            billing.only_plants(p_agg, ok), billing.only_plants(p_meta, ok), p_inverters,
                            p_access, p_expires);
  perform set_config('billing.guarded', 'off', true);
  -- new readings on a deleted plant: it has history again, so the delete date and "History
  -- deleted" go
  update billing.plants set history_purged_at = null
   where history_purged_at is not null and id = any (ok)
     and id in (select (e->>'plant_id')::bigint from jsonb_array_elements(coalesce(p_readings, '[]'::jsonb)) e
                union select (e->>'plant_id')::bigint from jsonb_array_elements(coalesce(p_agg, '[]'::jsonb)) e);
  return out || jsonb_build_object('refused', to_jsonb(array(
    select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k where k::bigint <> all (ok) order by 1)));
end $$;

-- 0250's poll_commit marks the other logins that see these plants read this minute, while
-- holding the plants. A login row an unlink or reconnect holds is skipped (as 0268's batch
-- does): waiting on it, with the plants held, deadlocks.
do $$
declare
  d text := pg_get_functiondef('public.poll_commit(uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb, text, bigint)'::regprocedure);
  old text := $q$  update private.sunsynk_accounts s
     set last_ok_at = now()
   where s.status = 'active' and s.id <> p_account
     and exists (select 1 from public.plant_users pu where pu.account_id = s.id and pu.plant_id = any(plants));$q$;
begin
  if position(old in d) = 0 then
    raise exception 'poll_commit changed since 0250: edit it by hand';
  end if;
  execute replace(d, old, $q$  update private.sunsynk_accounts s
     set last_ok_at = now()
   where s.id in (select o.id from private.sunsynk_accounts o
                   where o.status = 'active' and o.id <> p_account
                     and exists (select 1 from public.plant_users pu where pu.account_id = o.id and pu.plant_id = any(plants))
                   order by o.id for no key update skip locked);$q$);
end $$;

-- 0252's api_link_remove. Removing an own login: its login lock, plant locks and link rows,
-- then the account and the login's plants, before api_link_disconnect clears its inverters
-- and login row (a poll holds the plants and writes both).
create or replace function public.api_link_remove(p_account uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  acc uuid := billing.account_of(auth.uid(), false);
  shared bigint[];
  p bigint;
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and user_id = auth.uid())
     and not exists (select 1 from private.sunsynk_accounts a where a.id = p_account and a.kind = 'share'
                       and exists (select 1 from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid())) then
    raise exception 'not your account' using errcode = '42501';
  end if;
  shared := array(select x.plant_id from public.plant_users x where x.account_id = p_account and x.user_id = auth.uid());
  if exists (select 1 from private.sunsynk_accounts where id = p_account and kind = 'share') then
    perform private.share_release(p_account, auth.uid());
    if acc is not null and cardinality(shared) > 0 then perform billing.unclaim(acc, shared); end if;
  else
    perform pg_advisory_xact_lock_shared(3, 0);
    perform pg_advisory_xact_lock(1, hashtext(p_account::text));
    for p in select x.plant_id from public.plant_users x
              where x.account_id = p_account and x.user_id = auth.uid() order by x.plant_id loop
      perform pg_advisory_xact_lock(p);
    end loop;
    perform 1 from public.plant_users x
     where x.account_id = p_account and x.user_id = auth.uid() order by x.plant_id for update;
    if acc is not null and exists (select 1 from billing.logins where id = p_account and account = acc) then
      perform billing.lock_account(acc);
      perform billing.lock_plants(array(select plant from billing.login_plants where login = p_account));
    end if;
    perform public.api_link_disconnect(p_account);
    if acc is not null and exists (select 1 from billing.logins where id = p_account and account = acc) then
      perform billing.remove_login(acc, p_account);
    end if;
  end if;
  return jsonb_build_object('result', 'removed');
end $$;

-- ---------------------------------------------------------------------------
-- Pair 4. 0247's share_sync: the ended shares first (their link rows), then their accounts
-- and plants in id order (billing.run takes accounts in id order), then the writes.
-- ---------------------------------------------------------------------------
create or replace function public.share_sync(p_account uuid, p_plants bigint[])
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  now_s bigint := extract(epoch from now())::bigint;
  back int; missing int; gone int := 0;
  ended jsonb;
  g record;
  acc uuid;
begin
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (SOLAR-438)
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));

  -- in the list: a miss is forgotten (a stopped claim waits for its owner's Check)
  update public.plant_users pu set share_missing_at = null
   where pu.account_id = p_account and pu.via_share and pu.plant_id = any (p_plants)
     and pu.share_missing_at is not null and pu.share_gone_at is null;
  get diagnostics back = row_count;

  -- not in the list: first miss noted, so one bad list can't stop a plant
  update public.plant_users pu set share_missing_at = now()
   where pu.account_id = p_account and pu.via_share and pu.share_gone_at is null and pu.share_missing_at is null
     and pu.plant_id <> all (p_plants);
  get diagnostics missing = row_count;

  -- still missing an hour on: stop it, release the claim and tell the owner once
  with e as (
    update public.plant_users pu set share_gone_at = now()
     where pu.account_id = p_account and pu.via_share and pu.share_gone_at is null
       and pu.share_missing_at < now() - interval '50 minutes' and pu.plant_id <> all (p_plants)
    returning pu.user_id, pu.plant_id, pu.plant_name)
  select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'plant_id', plant_id, 'plant_name', plant_name)
                            order by plant_id, user_id), '[]') into ended from e;
  if jsonb_array_length(ended) = 0 then
    return jsonb_build_object('back', back, 'missing', missing, 'gone', 0);
  end if;
  perform 1 from billing.accounts a
   where a.user_id in (select (x->>'user_id')::uuid from jsonb_array_elements(ended) x)
   order by a.id for update;
  perform billing.lock_plants(array(select (x->>'plant_id')::bigint from jsonb_array_elements(ended) x));

  for g in select * from jsonb_to_recordset(ended) as r (user_id uuid, plant_id bigint, plant_name text) loop
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    values (g.user_id, g.plant_id, 'share_removed', 'share_removed:' || g.plant_id || ':' || now_s,
            jsonb_build_object('plants', jsonb_build_array(coalesce(g.plant_name, 'Plant ' || g.plant_id))), 1)
    on conflict do nothing;
    gone := gone + 1;
    acc := billing.account_of(g.user_id, false);
    if acc is not null and exists (select 1 from billing.plant_claims c where c.account = acc and c.plant = g.plant_id) then
      delete from billing.plant_claims where account = acc and plant = g.plant_id;
      update billing.plants set version = version + 1 where id = g.plant_id;
      update billing.accounts set version = version + 1 where id = acc;
      perform billing.log_event(acc, now(), 'share_gone', 'unclaim', null,
                                jsonb_build_object('plants', jsonb_build_array(g.plant_id), 'closed', '[]'::jsonb));
    end if;
  end loop;

  return jsonb_build_object('back', back, 'missing', missing, 'gone', gone);
end $$;
