-- ============================================================================
-- 0203 — the free week: every plant of one login runs, up to 5; the week starts
--        only for plants that run (SOLAR-552, decided by Brynne 2026-11-15).
--
-- Before: an unpaid account had one place. A login with several plants linked them
-- locked and the owner ticked one. The week of every newly linked plant started at
-- the link (0199), also for locked plants nobody opened.
--
-- Now, for an account with no plan:
--   - 5 places (billing_room). A login with up to 5 plants starts them all at the
--     link. With more than 5 the owner ticks 5 in the pop-up, as before.
--   - The ticks are fixed: api_plant_change is refused. They stay after an unlink
--     (private.plant_picks, 0197), so a second login only fills places still open.
--   - One SunSynk login at a time (link_login_allowed, called by link-sunsynk and
--     again by account_upsert).
--   - A plant's week and the account's week start when a plant of the account first
--     runs (private.week_start): at the link, or at the owner's tick. A locked plant
--     keeps its week. The two locks of 0199 stay: one week per account, one per plant.
--   - billing_free_week_start is gone: it wrote the account's row at the link, also
--     when no plant ran.
--
-- Paid plans are not changed: Home 2, Family 5, one change per 90 days.
-- ============================================================================

-- 0156's room. No plan: the free week's 5.
create or replace function public.billing_room(p_plan text, p_extra int default 0)
returns int language sql immutable as $$
  select case coalesce(p_plan, 'free')
    when 'family' then 5 + greatest(coalesce(p_extra, 0), 0)
    when 'home' then 2
    else 5 end
$$;

-- ---------------------------------------------------------------------------
-- One login for an account with no plan. True: this login may be linked.
-- ---------------------------------------------------------------------------
create or replace function public.link_login_allowed(p_user uuid, p_username text)
returns boolean
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select coalesce((select b.plan from private.billing b where b.user_id = p_user), 'free') <> 'free'
      or not exists (select 1 from private.sunsynk_accounts a
                      where a.user_id = p_user and a.kind = 'login' and lower(a.sunsynk_username) <> lower(p_username))
$$;
revoke all on function public.link_login_allowed(uuid, text) from public, anon, authenticated;
grant execute on function public.link_login_allowed(uuid, text) to service_role;

-- 0158's account_upsert, with the one-login check first.
create or replace function public.account_upsert(p_user uuid, p_username text, p_access text, p_expires bigint)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'private', 'pg_temp'
as $function$
declare acc uuid;
begin
  -- plant_users_upsert's order (0170), so two links at once queue here and the second sees the first's login
  perform pg_advisory_xact_lock_shared(3, 0);
  perform private.billing_lock(p_user);
  if not public.link_login_allowed(p_user, p_username) then
    raise exception 'one login' using errcode = '22023';
  end if;
  -- Before the upsert below wipes status and last_error. A first link has no row.
  insert into private.sunsynk_login_events (account_id, event, reason, last_ok_at, access_expires_at)
  select id, 'relinked', status || coalesce(': ' || last_error, ''), last_ok_at, access_expires_at
    from private.sunsynk_accounts
   where user_id = p_user and sunsynk_username = p_username;

  insert into private.sunsynk_accounts (user_id, sunsynk_username, access_token, access_expires_at, status, last_ok_at, last_error)
  values (p_user, p_username, p_access, p_expires, 'active', now(), null)
  on conflict (user_id, sunsynk_username) do update
    set access_token = excluded.access_token,
        access_expires_at = excluded.access_expires_at,
        status = 'active', last_ok_at = now(), last_error = null
  returning id into acc;
  -- A fresh sign-in replaces whatever the other copies held. The refresh token
  -- follows in account_refresh_set, which link-sunsynk calls next.
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires, status = 'active', last_error = null
   where id in (select private.login_copies(acc));
  return acc;
end $function$;

-- ---------------------------------------------------------------------------
-- The week, for plants of p_plants that run for this account now. 0199's rule:
--   - an account with no plan whose own week is not started, or is inside its 7
--     days, starts the week of each plant that has none;
--   - the account's row is written once, for every account: the earliest week
--     among these plants, or at least 15 days back when that week is over.
-- The caller holds the user lock and the plants' locks.
-- ---------------------------------------------------------------------------
create or replace function private.week_start(p_user uuid, p_plants bigint[])
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  run bigint[] := array(select pu.plant_id from public.plant_users pu
                         where pu.user_id = p_user and pu.plant_id = any (p_plants) and not pu.paused);
begin
  if cardinality(run) = 0 then return; end if;
  if coalesce((select plan from private.billing where user_id = p_user), 'free') = 'free'
     and coalesce((select f.started_at > now() - interval '7 days'
                     from private.free_week_logins f where f.user_id = p_user), true) then
    insert into private.plant_week (plant_id) select x from unnest(run) x
    on conflict (plant_id) do nothing;
  end if;
  insert into private.free_week_logins (sunsynk_username, user_id, started_at)
  select lower(coalesce((select a.sunsynk_username from public.plant_users pu
                           join private.sunsynk_accounts a on a.id = pu.account_id
                          where pu.user_id = p_user and pu.plant_id = run[1]), '')),
         p_user,
         case when w.s > now() - interval '7 days' then w.s
              else least(w.s, now() - interval '15 days') end
    from (select coalesce(min(started_at), now()) as s from private.plant_week where plant_id = any (run)) w
  on conflict (user_id) do nothing;
end $$;
revoke all on function private.week_start(uuid, bigint[]) from public, anon, authenticated;

-- 0197's plant_run, with the week: the owner's tick starts a locked plant.
create or replace function private.plant_run(p_user uuid, p_plant bigint)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare others boolean;
begin
  -- The plant's lock before its row, as billing_drop_plant and plant_start_fill take it.
  perform pg_advisory_xact_lock(p_plant);
  others := exists (select 1 from public.plant_users where plant_id = p_plant and not paused);
  update public.plant_users set paused = false where user_id = p_user and plant_id = p_plant and paused;
  if not found then return; end if;
  perform private.week_start(p_user, array[p_plant]);
  if not others then perform private.plant_start_fill(p_plant); end if;
  -- On no plan, or on any plan for a plant the failed card's move booked (0133): it collects, so it stays.
  update private.billing
     set plants_to_remove = array_remove(plants_to_remove, p_plant),
         remove_on = case when array_remove(plants_to_remove, p_plant) = '{}' then null else remove_on end,
         free_removals = array_remove(free_removals, p_plant),
         updated_at = now()
   where user_id = p_user and p_plant = any (plants_to_remove) and (plan = 'free' or p_plant = any (free_removals));
end $$;
revoke all on function private.plant_run(uuid, bigint) from public, anon, authenticated;

-- 0198's change, refused with no plan: the free week's ticks are fixed.
create or replace function public.api_plant_change(p_out bigint, p_in bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  uid uuid := auth.uid();
  last date;
  plant_in public.plant_users;
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(uid);
  if coalesce((select plan from private.billing where user_id = uid), 'free') = 'free' then
    raise exception 'no change without a plan' using errcode = '22023';
  end if;
  if (select state from private.billing where user_id = uid) = 'past_due' then
    raise exception 'pay the failed payment first' using errcode = '22023';
  end if;
  select changed_on into last from private.plant_change where user_id = uid;
  if last + 90 > private.billing_today() then
    raise exception 'next change %', to_char(last + 90, 'YYYY-MM-DD') using errcode = '22023';
  end if;
  if p_out is null or p_in is null or p_out = p_in
     or not exists (select 1 from private.plant_picks where user_id = uid and plant_id = p_out) then
    raise exception 'not picked' using errcode = '22023';
  end if;
  select * into plant_in from public.plant_users where user_id = uid and plant_id = p_in and share_gone_at is null;
  if not found then raise exception 'plant % is not linked to this user', p_in using errcode = '42501'; end if;
  if not plant_in.paused then raise exception 'already on' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(least(p_out, p_in));
  perform pg_advisory_xact_lock(greatest(p_out, p_in));

  update public.plant_users set paused = true where user_id = uid and plant_id = p_out and not paused;
  -- A plant someone else still collects keeps its readings; the wipe checks again when it runs (0125).
  if found and not exists (select 1 from public.plant_users where plant_id = p_out and not paused) then
    insert into private.plant_wipe (plant_id) values (p_out) on conflict (plant_id) do nothing;
  end if;
  delete from private.plant_picks where user_id = uid and plant_id = p_out;
  insert into private.plant_picks (user_id, plant_id, plant_name) values (uid, p_in, plant_in.plant_name)
  on conflict do nothing;
  perform private.plant_run(uid, p_in);

  insert into private.plant_change (user_id, changed_on) values (uid, private.billing_today())
  on conflict (user_id) do update set changed_on = excluded.changed_on;
  return public.api_plant_picks();
end $$;

-- ---------------------------------------------------------------------------
-- 0199's upsert. Two changes:
--   - an account with no plan ticks every new plant of a login that has 5 or fewer
--     (plant_pick_add stops at the places open); a login with one plant as before;
--   - the week goes through week_start, so only for the new plants that run.
-- ---------------------------------------------------------------------------
create or replace function public.plant_users_upsert(p_user uuid, p_account uuid, p_rows jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $$
declare
  p bigint;
  ids bigint[] := array(select (r->>'plant_id')::bigint from jsonb_array_elements(p_rows) r);
  login boolean;
  who text;
  fresh bigint[];
begin
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (0170)
  perform private.billing_lock(p_user);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  for p in select distinct x from unnest(ids) x order by 1 loop
    perform pg_advisory_xact_lock(p);
  end loop;
  select kind = 'login', sunsynk_username into login, who from private.sunsynk_accounts where id = p_account and status <> 'disabled';
  if not found then
    raise exception 'plant_users_upsert: account % is removed or disabled', p_account;
  end if;
  for p in
    select g.plant_id from private.plant_purge g
     where g.plant_id = any (ids)
     order by g.plant_id
  loop
    raise notice 'plant % relinked while waiting to be purged: wiping first (%)', p, private.purge_plant(p);
  end loop;

  fresh := array(select distinct x from unnest(ids) x
                  where not exists (select 1 from public.plant_users where user_id = p_user and plant_id = x)
                  order by x);

  if login and (cardinality(ids) = 1
                or (cardinality(ids) <= 5
                    and coalesce((select plan from private.billing where user_id = p_user), 'free') = 'free')) then
    perform private.plant_pick_add(p_user, (r->>'plant_id')::bigint, r->>'plant_name')
       from jsonb_array_elements(p_rows) r
      where (r->>'plant_id')::bigint = any (fresh)
      order by (r->>'plant_id')::bigint;
  end if;

  insert into public.plant_users (plant_id, user_id, account_id, plant_name)
  select (r->>'plant_id')::bigint, p_user, p_account, r->>'plant_name'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id, user_id) do update
    set account_id = excluded.account_id, plant_name = excluded.plant_name;

  perform private.week_start(p_user, fresh);

  if login and cardinality(ids) > 0 then
    update public.plant_users set share_missing_at = null, share_gone_at = null
     where account_id = p_account and user_id = p_user and not via_share and plant_id = any (ids)
       and (share_missing_at is not null or share_gone_at is not null);
    -- gone: not read any more; its owner is told once what can be done
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
    from jsonb_array_elements(p_rows) r
   order by (r->>'plant_id')::bigint
   limit 1
  on conflict (key) do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- 0197's claim, without billing_free_week_start: the upsert and plant_run start
-- the week when the claimed plant runs.
-- ---------------------------------------------------------------------------
create or replace function public.share_claim(p_user uuid, p_account uuid, p_plant bigint, p_plant_name text)
returns text
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  mine public.plant_users;
  lapsed uuid[];
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and kind = 'share' and status <> 'disabled') then
    raise exception 'share_claim: % is not the share login', p_account;
  end if;
  -- plant_users_upsert's order: user, account, plant. Two claims of one plant queue here.
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (SOLAR-438)
  perform private.billing_lock(p_user);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  perform pg_advisory_xact_lock(p_plant);

  select * into mine from public.plant_users where plant_id = p_plant and user_id = p_user;
  if found and (not mine.via_share or mine.share_gone_at is null) then return 'yours'; end if;
  if exists (select 1 from public.plant_users o
              where o.plant_id = p_plant and o.user_id <> p_user and (not o.via_share or o.share_gone_at is null)) then
    return 'taken';
  end if;

  -- A claim that lapsed when the share was removed gives way to this one.
  with d as (delete from public.plant_users
              where plant_id = p_plant and user_id <> p_user and via_share and share_gone_at is not null
             returning user_id)
  select coalesce(array_agg(user_id), '{}') into lapsed from d;
  delete from public.email_queue where plant_id = p_plant and user_id = any (lapsed) and status = 'queued';

  -- the tick first, so the new row starts when the account has a place (0197)
  perform private.plant_pick_add(p_user, p_plant, p_plant_name);
  perform public.plant_users_upsert(p_user, p_account,
    jsonb_build_array(jsonb_build_object('plant_id', p_plant, 'plant_name', p_plant_name)));
  update public.plant_users set via_share = true, share_missing_at = null, share_gone_at = null
   where plant_id = p_plant and user_id = p_user;
  -- this user's own claim, lapsed and shared again: its row is there, locked
  if exists (select 1 from private.plant_picks where user_id = p_user and plant_id = p_plant) then
    begin
      perform private.plant_run(p_user, p_plant);
    exception when sqlstate '22023' then
      null;  -- no place: it stays locked
    end;
  end if;
  return case when (select paused from public.plant_users where plant_id = p_plant and user_id = p_user)
              then 'claimed_paused' else 'claimed' end;
end $$;

drop function if exists public.billing_free_week_start(uuid, text);

notify pgrst, 'reload schema';
