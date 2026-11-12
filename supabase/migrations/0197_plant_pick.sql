-- ============================================================================
-- 0197 — the owner ticks which plants run; after that, one change every 90 days
--        (SOLAR-537, decided by Brynne 2026-11-12).
--
-- Before: the owner stopped and started plants without limit (0125), so a Home
-- account could watch 5 plants in turns (cheating review 2026-11-12, finding 2).
--
-- Now:
--   - private.plant_picks: the plants an account ticked. It stays with the account
--     and the plant, not with the link row: removing a login keeps its ticks.
--       held = true   the tick holds one of the plan's places (the plant runs, or its
--                     login is removed and the place waits for it).
--       held = false  the plan got smaller (downgrade, cancel, failed card) and the
--                     plant lost its place. It comes back free when the plan has
--                     room again; no other plant takes that place without a change.
--   - A plant runs (plant_users.paused = false) only with a tick. A plant with no
--     tick is locked (paused = true): listed by name, no data.
--   - A new tick needs fewer ticks than the plan's room (billing_room). Filling an
--     empty place is free, at any time.
--   - api_plant_pick: tick locked plants into open places (the pop-up after a link,
--     and the locked row).
--   - api_plant_change: one plant out, one locked plant in. The plant that goes out
--     loses its tick, and its history at once (private.plant_wipe, as 0125's stop).
--     One per account per 90 days (private.plant_change); the first is ready at once.
--   - A plant gone from SunSynk loses its tick, so its place opens: a removed share
--     (share_gone_at, 0172), or a plant missing from its login's list twice, 50
--     minutes apart (the same two columns, set in plant_users_upsert).
--   - A login with one plant starts it with no pop-up when a place is open. A share
--     claim counts as a tick. A payment that names a plant ticks it.
--   - api_plant_stop and api_plant_start are gone. To delete a plant's data the
--     owner removes the login.
--
-- Existing rows: running plants are ticked, stopped plants are locked, the change
-- is ready.
--
-- Reset an account's change by hand (until admin has a button):
--   delete from private.plant_change where user_id = '<user id>';
--
-- Lock order unchanged: the user lock (billing_lock), then plants in id order.
-- ============================================================================

create table if not exists private.plant_picks (
  user_id    uuid not null references auth.users (id) on delete cascade,
  plant_id   bigint not null,
  plant_name text,
  held       boolean not null default false,
  picked_at  timestamptz not null default now(),
  primary key (user_id, plant_id)
);
alter table private.plant_picks enable row level security;

create table if not exists private.plant_change (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  changed_on date not null  -- the South African day (private.billing_today)
);
alter table private.plant_change enable row level security;

-- Existing rows. A plant the failed-card move to Free stopped keeps its tick without
-- its place, so paying brings it back (billing_resume).
insert into private.plant_picks (user_id, plant_id, plant_name, held)
select pu.user_id, pu.plant_id, pu.plant_name, not pu.paused
  from public.plant_users pu
  left join private.billing b on b.user_id = pu.user_id
 where pu.share_gone_at is null
   and (not pu.paused or pu.plant_id = any (coalesce(b.free_removals, '{}')))
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- A new tick, when the account has fewer ticks than its plan has places. The caller
-- holds the user lock. False: no place.
-- ---------------------------------------------------------------------------
create or replace function private.plant_pick_add(p_user uuid, p_plant bigint, p_name text)
returns boolean language plpgsql set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if exists (select 1 from private.plant_picks where user_id = p_user and plant_id = p_plant) then return true; end if;
  select * into b from private.billing where user_id = p_user;
  if not coalesce(b.comped, false)
     and (select count(*) from private.plant_picks where user_id = p_user) >= public.billing_room(b.plan, b.extra_plants) then
    return false;
  end if;
  insert into private.plant_picks (user_id, plant_id, plant_name) values (p_user, p_plant, p_name);
  return true;
end $$;
revoke all on function private.plant_pick_add(uuid, bigint, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 0136's limit, with the tick. A plant starts (a new row, or paused set to false)
-- only with a tick and a place:
--   'no room'      as many plants run as the plan allows
--   'plan change'  a new link under a booked smaller plan that is full (0136)
--   'not picked'   the plant has no tick
--   'place taken'  its tick lost its place and every place is held
-- A new row that can't start links locked; an update is refused (22023).
-- A running plant that is locked keeps its tick without its place.
-- ---------------------------------------------------------------------------
create or replace function private.plant_users_plan_limit()
returns trigger language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  k private.plant_picks;
  act int;
  kept int;
  room int;
  why text;
begin
  if tg_op = 'UPDATE' and new.paused and not old.paused then
    update private.plant_picks set held = false where user_id = new.user_id and plant_id = new.plant_id;
    return new;
  end if;
  if new.paused or (tg_op = 'UPDATE' and not old.paused) then return new; end if;
  -- A row already linked (the hourly sync's upsert): ON CONFLICT keeps its paused.
  if tg_op = 'INSERT' and exists (select 1 from public.plant_users where user_id = new.user_id and plant_id = new.plant_id) then
    return new;
  end if;
  perform private.billing_lock(new.user_id);
  -- after the lock: what the transaction before us committed
  select * into b from private.billing where user_id = new.user_id;
  if coalesce(b.comped, false) then
    insert into private.plant_picks (user_id, plant_id, plant_name, held)
    values (new.user_id, new.plant_id, new.plant_name, true)
    on conflict (user_id, plant_id) do update set held = true;
    return new;
  end if;
  room := public.billing_room(b.plan, b.extra_plants);
  select * into k from private.plant_picks where user_id = new.user_id and plant_id = new.plant_id;
  select count(*), count(*) filter (where plant_id <> all (coalesce(b.plants_to_remove, '{}')))
    into act, kept
    from public.plant_users
   where user_id = new.user_id and not paused and plant_id <> new.plant_id;
  if act >= room then
    why := 'no room';
  elsif tg_op = 'INSERT' and kept >= coalesce(private.billing_next_room(b), 2147483647) then
    why := 'plan change';
  elsif k.user_id is null then
    why := 'not picked';
  elsif not k.held and (select count(*) from private.plant_picks
                         where user_id = new.user_id and held and plant_id <> new.plant_id) >= room then
    why := 'place taken';
  else
    update private.plant_picks set held = true where user_id = new.user_id and plant_id = new.plant_id;
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.paused := true;
    update private.plant_picks set held = false where user_id = new.user_id and plant_id = new.plant_id;
    return new;
  end if;
  raise exception '%', why using errcode = '22023';
end $$;
revoke all on function private.plant_users_plan_limit() from public, anon, authenticated;

-- A plant gone from SunSynk is locked and loses its tick: its place opens.
create or replace function private.plant_users_gone()
returns trigger language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  if new.share_gone_at is not null and old.share_gone_at is null then
    new.paused := true;
    delete from private.plant_picks where user_id = new.user_id and plant_id = new.plant_id;
  end if;
  return new;
end $$;
revoke all on function private.plant_users_gone() from public, anon, authenticated;
drop trigger if exists plant_users_gone on public.plant_users;
create trigger plant_users_gone before update of share_gone_at on public.plant_users
  for each row execute function private.plant_users_gone();

-- Shares removed before this migration.
update public.plant_users set paused = true where share_gone_at is not null and not paused;

-- ---------------------------------------------------------------------------
-- What the pick screens read: the plan and its places, the ticks, and the day the
-- next change opens (null: ready).
-- ---------------------------------------------------------------------------
create or replace function public.api_plant_picks()
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object(
    'plan', coalesce((select b.plan from private.billing b where b.user_id = auth.uid()), 'free'),
    -- free of charge: no limit, so the screens show no number
    'comped', coalesce((select b.comped from private.billing b where b.user_id = auth.uid()), false),
    'room', (select public.billing_room(b.plan, b.extra_plants)
               from (select auth.uid() u) me left join private.billing b on b.user_id = me.u),
    'change_on', (select c.changed_on + 90 from private.plant_change c
                   where c.user_id = auth.uid() and c.changed_on + 90 > private.billing_today()),
    'picks', coalesce((select jsonb_agg(jsonb_build_object(
                         'plant_id', k.plant_id,
                         'plant_name', coalesce(pu.plant_name, k.plant_name, 'Plant ' || k.plant_id),
                         'held', k.held,
                         'linked', pu.plant_id is not null,
                         'running', coalesce(not pu.paused, false))
                       order by k.picked_at, k.plant_id)
                from private.plant_picks k
                left join public.plant_users pu on pu.user_id = k.user_id and pu.plant_id = k.plant_id
               where k.user_id = auth.uid()), '[]'::jsonb))
$$;
revoke all on function public.api_plant_picks() from public, anon;
grant execute on function public.api_plant_picks() to authenticated, service_role;

-- Starts one locked plant of the caller's that has its tick. 0133's api_plant_start
-- body: the fill when nobody else collects it, and off the delete lists.
create or replace function private.plant_run(p_user uuid, p_plant bigint)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare others boolean;
begin
  -- The plant's lock before its row, as billing_drop_plant and plant_start_fill take it.
  perform pg_advisory_xact_lock(p_plant);
  others := exists (select 1 from public.plant_users where plant_id = p_plant and not paused);
  update public.plant_users set paused = false where user_id = p_user and plant_id = p_plant and paused;
  if not found then return; end if;
  if not others then perform private.plant_start_fill(p_plant); end if;
  -- On Free, or on any plan for a plant the move to Free booked (0133): it collects, so it stays.
  update private.billing
     set plants_to_remove = array_remove(plants_to_remove, p_plant),
         remove_on = case when array_remove(plants_to_remove, p_plant) = '{}' then null else remove_on end,
         free_removals = array_remove(free_removals, p_plant),
         updated_at = now()
   where user_id = p_user and p_plant = any (plants_to_remove) and (plan = 'free' or p_plant = any (free_removals));
end $$;
revoke all on function private.plant_run(uuid, bigint) from public, anon, authenticated;

-- Tick locked plants into open places. All of them, or none.
create or replace function public.api_plant_pick(p_plants bigint[])
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  uid uuid := auth.uid();
  r record;
  n int := 0;
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(uid);
  for r in select pu.plant_id, pu.plant_name, pu.paused from public.plant_users pu
            where pu.user_id = uid and pu.plant_id = any (coalesce(p_plants, '{}')) and pu.share_gone_at is null
            order by pu.plant_id loop
    n := n + 1;
    continue when not r.paused;
    if not private.plant_pick_add(uid, r.plant_id, r.plant_name) then
      raise exception 'no room' using errcode = '22023';
    end if;
    perform private.plant_run(uid, r.plant_id);
  end loop;
  if n <> (select count(distinct x) from unnest(coalesce(p_plants, '{}')) x) then
    raise exception 'a plant is not linked to this user' using errcode = '42501';
  end if;
  return public.api_plant_picks();
end $$;
revoke all on function public.api_plant_pick(bigint[]) from public, anon;
grant execute on function public.api_plant_pick(bigint[]) to authenticated, service_role;

-- One ticked plant out, one locked plant in. Refused inside 90 days of the last
-- change: 'next change <date>'.
create or replace function public.api_plant_change(p_out bigint, p_in bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  uid uuid := auth.uid();
  last date;
  plant_in public.plant_users;
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(uid);
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
revoke all on function public.api_plant_change(bigint, bigint) from public, anon;
grant execute on function public.api_plant_change(bigint, bigint) to authenticated, service_role;

drop function if exists public.api_plant_stop(bigint);
drop function if exists public.api_plant_start(bigint);

-- ---------------------------------------------------------------------------
-- 0133's resume. Plants a payment names are ticked. With none named, only plants
-- that have a tick start again: a plant never ticked waits for its owner.
-- ---------------------------------------------------------------------------
create or replace function private.billing_resume(p_user uuid, p_plants bigint[])
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  r record;
  others boolean;
begin
  perform private.billing_lock(p_user);
  -- plant locks in plant id order first, as links take them (0132)
  perform pg_advisory_xact_lock(x.plant_id) from (select pu.plant_id from public.plant_users pu
     where pu.user_id = p_user and pu.paused and (p_plants is null or pu.plant_id = any (p_plants)) order by pu.plant_id) x;
  for r in select pu.plant_id, pu.plant_name from public.plant_users pu
            where pu.user_id = p_user and pu.paused and pu.share_gone_at is null
              and (p_plants is null or pu.plant_id = any (p_plants))
            order by pu.linked_at, pu.plant_id loop
    perform pg_advisory_xact_lock(r.plant_id);
    if p_plants is not null then perform private.plant_pick_add(p_user, r.plant_id, r.plant_name); end if;
    others := exists (select 1 from public.plant_users where plant_id = r.plant_id and not paused);
    begin
      update public.plant_users set paused = false where user_id = p_user and plant_id = r.plant_id;
    exception when sqlstate '22023' then
      if sqlerrm = 'no room' then exit; end if;  -- the room is full
      continue;                                  -- no tick, or its place is taken
    end;
    if not others then perform private.plant_start_fill(r.plant_id); end if;
    update private.billing
       set plants_to_remove = array_remove(plants_to_remove, r.plant_id), free_removals = array_remove(free_removals, r.plant_id),
           remove_on = case when array_remove(plants_to_remove, r.plant_id) = '{}' then null else remove_on end
     where user_id = p_user and r.plant_id = any (plants_to_remove);
  end loop;
end $$;
revoke all on function private.billing_resume(uuid, bigint[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 0136's move to Free. The plant it keeps starts only if it has a tick: an account
-- whose plants are all locked keeps them locked.
-- ---------------------------------------------------------------------------
create or replace function private.billing_to_free(p_user uuid, p_today date)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  keep bigint;
  stop bigint[];
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  -- the first pick, else the first linked plant not booked for deletion; all booked: the first linked (0131)
  select plant_id into keep from public.plant_users where user_id = p_user
   order by plant_id = any (coalesce(b.plants_to_remove, '{}')), paused,
            array_position(b.next_keep, plant_id) nulls last, linked_at, plant_id limit 1;
  select coalesce(array_agg(plant_id order by plant_id), '{}') into stop
    from public.plant_users where user_id = p_user and plant_id is distinct from keep;
  update private.billing
     set plan = 'free', period = null, billing_day = null, next_billing_date = null,
         next_plan = null, next_period = null, extra_plants = 0, next_extra_plants = null, next_keep = '{}',
         state = 'active', past_due_since = null,
         plants_to_remove = array(select distinct x from unnest(plants_to_remove || stop) x order by x),
         free_removals = array(select distinct x from unnest(free_removals || stop) x order by x),
         remove_on = case when cardinality(stop) > 0 then p_today + 30 else remove_on end,
         updated_at = now()
   where user_id = p_user;
  update public.plant_users set paused = true where user_id = p_user and plant_id is distinct from keep and not paused;
  -- a kept plant that was locked starts only with its tick (0197), and refetches as every start does (0131)
  if exists (select 1 from public.plant_users pu join private.plant_picks k on k.user_id = pu.user_id and k.plant_id = pu.plant_id
              where pu.user_id = p_user and pu.plant_id = keep and pu.paused and pu.share_gone_at is null) then
    begin
      if not exists (select 1 from public.plant_users where plant_id = keep and not paused) then
        update public.plant_users set paused = false where user_id = p_user and plant_id = keep;
        perform private.plant_start_fill(keep);
      else
        update public.plant_users set paused = false where user_id = p_user and plant_id = keep;
      end if;
    exception when sqlstate '22023' then
      null;  -- its place is held by a plant whose login is removed: it stays locked
    end;
  end if;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (p_user, 'bill_free', 'bill_free:' || p_today,
          jsonb_build_object('from', b.plan, 'deleteOn', p_today + 30,
            'kept', coalesce((select plant_name from public.plant_users where user_id = p_user and plant_id = keep), ''),
            'stopped', coalesce((select jsonb_agg(plant_name order by linked_at) from public.plant_users
                                  where user_id = p_user and plant_id = any (stop)), '[]'::jsonb)),
          1)
  on conflict do nothing;
end $$;
revoke all on function private.billing_to_free(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 0170's upsert, with two additions for a password login:
--   - a login with one plant ticks it when a place is open, so it starts with no pop-up;
--   - a plant of this login missing from SunSynk's list twice, 50 minutes apart, is
--     marked gone (the share columns, 0172): locked, its place open. Back in the
--     list, the mark clears and the plant waits locked for its owner's tick.
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
begin
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (0170)
  perform private.billing_lock(p_user);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  for p in select distinct x from unnest(ids) x order by 1 loop
    perform pg_advisory_xact_lock(p);
  end loop;
  select kind = 'login' into login from private.sunsynk_accounts where id = p_account and status <> 'disabled';
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

  if login and cardinality(ids) = 1
     and not exists (select 1 from public.plant_users where user_id = p_user and plant_id = ids[1]) then
    perform private.plant_pick_add(p_user, ids[1], p_rows->0->>'plant_name');
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
    update public.plant_users set share_gone_at = now()
     where account_id = p_account and user_id = p_user and not via_share and share_gone_at is null
       and share_missing_at < now() - interval '50 minutes' and plant_id <> all (ids);
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
-- 0172's claim: it counts as a tick. 'claimed_paused' when the account has no place.
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
  -- the free week is per user (0121); the key only records where it came from
  perform public.billing_free_week_start(p_user, 'share:' || p_plant);
  return case when (select paused from public.plant_users where plant_id = p_plant and user_id = p_user)
              then 'claimed_paused' else 'claimed' end;
end $$;

-- ---------------------------------------------------------------------------
-- 0188's api_link_status, with each plant's tick: picked, and can_start (it is
-- locked and a place is open for it, so the owner's tick starts it); and started_at.
-- ---------------------------------------------------------------------------
create or replace function public.api_link_status()
 returns table(account_id uuid, sunsynk_username text, status text, linked_at timestamptz, last_ok_at timestamptz, plants jsonb, kind text)
 language sql
 security definer
 set search_path to 'public', 'private', 'pg_temp'
as $function$
  with me as (select auth.uid() u),
  b as (select me.u user_id, bl.plants_to_remove, bl.remove_on, bl.free_removals, bl.prepaid_on, bl.next_billing_date, bl.billing_day,
               coalesce(bl.comped, false) comped,
               coalesce(private.billing_drops(bl), '{}') drops,
               public.billing_room(bl.plan, bl.extra_plants) room,
               (select count(*) from public.plant_users x where x.user_id = me.u and not x.paused) act,
               (select count(*) from private.plant_picks k where k.user_id = me.u) picks,
               (select count(*) from private.plant_picks k where k.user_id = me.u and k.held) held
          from me left join private.billing bl on bl.user_id = me.u)
  select a.id, a.sunsynk_username, a.status,
         -- the share login: when this user first claimed through it
         case when a.kind = 'share' then (select min(x.linked_at) from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid())
              else a.linked_at end,
         a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name,
                                                        'paused', pu.paused, 'linked_at', pu.linked_at,
                                                        'inverters', (select count(*) from private.inverters i where i.plant_id = pu.plant_id),
                                                        'remove_on', case when pu.plant_id = any (b.plants_to_remove) then b.remove_on
                                                                          when pu.plant_id = any (b.drops) then private.billing_end_day(b.prepaid_on, b.next_billing_date, b.billing_day) end,
                                                        'drop', coalesce(pu.plant_id = any (b.drops), false),
                                                        'free_removal', coalesce(pu.plant_id = any (b.plants_to_remove) and pu.plant_id = any (b.free_removals), false),
                                                        -- gone from SunSynk: the share removed (0172), or off its login's list (0197)
                                                        'share_gone', pu.share_gone_at is not null,
                                                        'picked', k.plant_id is not null,
                                                        -- epoch it last started collecting (0174): a plant with no reading 30 min on says so
                                                        'started_at', (select s.started_at from private.plant_alert_state s where s.plant_id = pu.plant_id),
                                                        'can_start', pu.paused and pu.share_gone_at is null
                                                                     and (b.comped or (b.act < b.room and case
                                                                           when k.plant_id is null then b.picks < b.room
                                                                           when k.held then true
                                                                           else b.held < b.room end)))
                                    order by pu.linked_at, pu.plant_id)
                     from public.plant_users pu
                     join b on b.user_id = pu.user_id
                     left join private.plant_picks k on k.user_id = pu.user_id and k.plant_id = pu.plant_id
                    where pu.account_id = a.id and pu.user_id = auth.uid()),
                  '[]'::jsonb),
         a.kind
    from private.sunsynk_accounts a
   where a.user_id = auth.uid()
      or (a.kind = 'share' and exists (select 1 from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid()))
   order by 4 desc
$function$;

-- ---------------------------------------------------------------------------
-- 0155's payment, one test changed: "paid plants did not start" counts only plants
-- that could start. A locked plant never ticked is not started by a payment that
-- does not name it, and a plant whose place waits for another plant (a removed
-- login's tick) stays locked: neither reads as a start refused part way.
-- ---------------------------------------------------------------------------
create or replace function public.billing_charge_paid(p_reference text, p_card jsonb default null, p_quiet boolean default false,
  p_cents bigint default null, p_email text default null, p_paid_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  today date := private.billing_today();
  v_from text;
  stale text;
  reusable boolean := p_card is not null and coalesce((p_card->>'reusable')::boolean, false);
  new_card boolean;
  named bigint[];
  room int;
  room_only boolean := false;  -- more room on the same plan, no plant named (0131)
  across boolean := false;     -- a bigger plan in a new period, from today (SOLAR-364)
  credit int;                  -- its unused days of the old plan, as the quote took them off
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then raise exception 'unknown reference' using errcode = 'P0002'; end if;
  perform private.billing_lock(c.user_id);
  select * into b from private.billing where user_id = c.user_id for update;
  -- Paystack saves a card under a new code; the same code is the card held.
  new_card := reusable and (p_card->>'authorization_code') is distinct from (b.card->>'authorization_code');
  if c.kind = 'card' then
    if c.status <> 'paid' then
      if p_cents is not null and p_cents <> c.amount * 100 then
        raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
      end if;
      update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;
      if new_card then
        update private.billing
           set card = p_card, card_email = coalesce(p_email, c.email, (select email from auth.users where id = c.user_id)),
               updated_at = now()
         where user_id = c.user_id;
      elsif not reusable then
        update private.billing_charges set error = 'card not reusable: not saved' where reference = p_reference;
      end if;
    end if;
    return jsonb_build_object('status', 'paid', 'kind', 'card', 'refund', coalesce(c.refund_status, 'failed') = 'failed',
      'saved', reusable);
  end if;
  if c.status = 'paid' then
    -- Marked for refund: every report of it says so, until Paystack has taken the refund.
    if c.error like 'refund%' then
      return jsonb_build_object('status', 'paid', 'applied', false, 'kind', c.kind,
        'refund', coalesce(c.refund_status, 'failed') = 'failed');
    end if;
    return jsonb_build_object('status', 'paid', 'again', true, 'kind', c.kind);
  end if;
  if p_cents is not null and p_cents <> c.amount * 100 then
    raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
  end if;
  v_from := coalesce(b.plan, 'free');
  -- Paystack reported a refund before the payment: the money is going back, so the
  -- payment never applies.
  if c.refund_status is not null then
    update private.billing_charges set status = 'paid', settled_at = now(),
           error = 'refund: refunded at Paystack before the payment was reported'
     where reference = p_reference
    returning * into c;
    -- the refund events came while the charge was pending, so none sent the email (0131)
    perform private.billing_refund_mail(c);
    raise warning 'billing charge % paid after its refund: not applied', p_reference;
    return jsonb_build_object('status', 'paid', 'applied', false, 'kind', c.kind, 'refund', c.refund_status = 'failed');
  end if;
  stale := private.billing_charge_stale(c, b, (p_paid_at at time zone 'Africa/Johannesburg')::date);
  if stale is null then
    begin
      update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;

      if c.kind = 'start' then
        insert into private.billing (user_id, plan, period, billing_day, next_billing_date, extra_plants)
        values (c.user_id, c.plan, c.period, extract(day from today)::int,
                public.billing_step(today, c.period, extract(day from today)::int, 1), c.extra_plants)
        on conflict (user_id) do update
          set plan = excluded.plan, period = excluded.period, billing_day = excluded.billing_day,
              next_billing_date = excluded.next_billing_date, extra_plants = excluded.extra_plants,
              next_plan = null, next_period = null, next_extra_plants = null,
              state = 'active', past_due_since = null, updated_at = now();
        -- The cap holds at payment: a card page opened before the last place went pays its
        -- quoted price this once, then the usual price. The lock makes two last payers queue.
        if c.offer_id is not null then perform pg_advisory_xact_lock(hashtext('offer:' || c.offer_id)); end if;
        if c.offer_id is not null and exists (select 1 from private.offers o where o.id = c.offer_id
             and (o.max_payers is null or (select count(*) from private.offer_members m where m.offer_id = o.id) < o.max_payers)) then
          update private.billing b2
             set offer_id = c.offer_id,
                 offer_until = (select (today + make_interval(months => o.months))::date from private.offers o
                                 where o.id = c.offer_id and o.months is not null)
           where b2.user_id = c.user_id;
          insert into private.offer_members (offer_id, user_id, joined_on) values (c.offer_id, c.user_id, today)
          on conflict do nothing;
        end if;
      elsif c.kind = 'upgrade' and c.period is distinct from b.period then
        -- a new year from today: a new billing date, and nothing booked carries over
        across := true;
        credit := public.billing_prorate(public.billing_amount(b.plan, b.period, 0, private.billing_offer(c.user_id, today)), today,
                    public.billing_step(b.next_billing_date, b.period, b.billing_day, -1), b.next_billing_date);
        update private.billing
           set plan = c.plan, period = c.period, billing_day = extract(day from today)::int,
               next_billing_date = public.billing_step(today, c.period, extract(day from today)::int, 1),
               extra_plants = c.extra_plants, next_plan = null, next_period = null, next_extra_plants = null,
               next_keep = '{}', updated_at = now()
         where user_id = c.user_id;
      elsif c.kind = 'upgrade' then
        update private.billing
           set next_plan = case when plan = c.plan then next_plan end, plan = c.plan,
               extra_plants = c.extra_plants, next_extra_plants = null, updated_at = now()
         where user_id = c.user_id;
      elsif c.kind = 'switch' then
        -- yearly from the billing date, that renewal already paid (0138)
        update private.billing set next_period = 'yearly', prepaid_on = c.billing_date, updated_at = now()
         where user_id = c.user_id;
      else  -- renewal, settle
        update private.billing set state = 'active', past_due_since = null, updated_at = now() where user_id = c.user_id;
      end if;
      if c.kind in ('start', 'upgrade') then
        -- The plants the room was bought for, if still stopped; else the oldest stopped.
        named := array(select plant_id from public.plant_users
                        where user_id = c.user_id and paused and plant_id = any (coalesce(c.plants, '{}')));
        -- More room on the same plan, no plant named: as many as bought, newest first
        -- (plants that linked stopped), not every plant the user stopped on purpose (0131).
        if cardinality(named) = 0 and c.kind = 'upgrade' and v_from = c.plan then
          room_only := true;  -- none to start (all booked for removal) starts none
          named := array(select plant_id from public.plant_users where user_id = c.user_id and paused
                            and plant_id <> all (coalesce(b.plants_to_remove, '{}'))
                          order by linked_at desc, plant_id desc limit greatest(c.added, 0));
        end if;
        if cardinality(named) > 0 or not room_only then
          perform private.billing_resume(c.user_id, case when cardinality(named) > 0 then named end);
        end if;
        -- A bigger plan fills the rest of its room too, oldest first (0131): the named plant
        -- first, then the plants the old plan's limit stopped.
        if cardinality(named) > 0 and v_from <> c.plan then perform private.billing_resume(c.user_id, null); end if;
        select * into b from private.billing where user_id = c.user_id;
        room := least(public.billing_room(b.plan, b.extra_plants), coalesce(private.billing_next_room(b), 2147483647));
        -- Room left and a plant to start still stopped: the start was refused part way.
        if (select count(*) from public.plant_users where user_id = c.user_id and not paused) < room
           and exists (select 1 from public.plant_users pu where pu.user_id = c.user_id and pu.paused and pu.share_gone_at is null
                        -- a plant that could start: it has a tick, and a place is not held for another plant (0197)
                        and exists (select 1 from private.plant_picks k where k.user_id = pu.user_id and k.plant_id = pu.plant_id)
                        and (select count(*) from private.plant_picks k where k.user_id = pu.user_id and k.held)
                            < public.billing_room(b.plan, b.extra_plants)
                        and ((cardinality(named) = 0 and not room_only) or pu.plant_id = any (named))) then
          raise exception 'paid plants did not start' using errcode = 'BL001';
        end if;
      end if;
      if new_card then
        update private.billing
           set card = p_card, card_email = coalesce(p_email, c.email, (select email from auth.users where id = c.user_id))
         where user_id = c.user_id;
      end if;
    exception when sqlstate 'BL001' then
      stale := 'paid plants did not start';
    end;
  end if;
  if stale is not null then
    update private.billing_charges set status = 'paid', settled_at = now(),
           error = case when stale = 'paid plants did not start' then 'refund: ' || stale
                        else 'refund: paid after the account changed (' || stale || '; ' || v_from || ', ' || coalesce(b.state, 'active') || ')' end
     where reference = p_reference;
    raise warning 'billing charge % paid but not applied (%): refund it', p_reference, stale;
    return jsonb_build_object('status', 'paid', 'applied', false, 'kind', c.kind, 'refund', true);
  end if;

  if not p_quiet then
    select * into b from private.billing where user_id = c.user_id;
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (c.user_id,
            case when c.kind in ('start', 'upgrade') then 'bill_upgraded' when c.kind = 'switch' then 'bill_switched' else 'bill_paid' end,
            'bill:' || p_reference,
            jsonb_build_object('from', v_from, 'to', b.plan, 'plan', b.plan, 'period', b.period,
              'amount', c.amount, 'date', today, 'reference', p_reference,
              'card', private.billing_card_label(coalesce(p_card, b.card)),
              'added', c.added, 'daysLeft', b.next_billing_date - today, 'credit', credit,
              -- a switch: the extras and price of the year it paid for
              'extra', case when c.kind = 'switch' then c.extra_plants else b.extra_plants end,
              'extraEach', public.billing_amount('family', case when c.kind = 'switch' then 'yearly' else b.period end, 1,
                             private.billing_offer(c.user_id, b.next_billing_date))
                         - public.billing_amount('family', case when c.kind = 'switch' then 'yearly' else b.period end, 0,
                             private.billing_offer(c.user_id, b.next_billing_date)),
              'nextAmount', public.billing_amount_due(c.user_id),
              -- a switch: the year starts on the billing date and is paid, so the next is a year on
              'startsOn', b.next_billing_date,
              'nextDate', case when c.kind = 'switch' then public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1)
                               else b.next_billing_date end),
            1)
    on conflict do nothing;
  end if;
  return jsonb_build_object('status', 'paid', 'plan', b.plan, 'kind', c.kind);
end $$;

-- ---------------------------------------------------------------------------
-- 0114's email rule: no mail for a locked plant, but the "share removed" email
-- still goes. The plant is locked in the statement that queues it (plant_users_gone).
-- ---------------------------------------------------------------------------
create or replace function private.email_skip_paused()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.plant_id is not null and new.kind <> 'share_removed' and exists (select 1 from public.plant_users pu
       where pu.user_id = new.user_id and pu.plant_id = new.plant_id and pu.paused) then
    return null;
  end if;
  -- Free with a free week on record: no reports but the day-7 one.
  if new.kind like 'report\_%' and not coalesce((new.data->>'freeWeekEnds')::boolean, false)
     and coalesce((select b.plan from private.billing b where b.user_id = new.user_id), 'free') = 'free'
     and exists (select 1 from private.free_week_logins f where f.user_id = new.user_id) then
    return null;
  end if;
  return new;
end $$;

notify pgrst, 'reload schema';
