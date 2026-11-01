-- ============================================================================
-- 0136 — a downgrade picks the plants it keeps; the rest collect to the billing date
-- (SOLAR-295, decided by Brynne 2026-11-01, option 1).
--
-- A downgrade (Family to Home, Cancel to Free, or fewer extra plants on Family) was
-- refused until plants were turned off ("remove plants first"), which stopped them and
-- deleted their history at once. Now it books, with the plants the booked plan keeps:
--   - private.billing.next_keep: the user's pick, in order. Not a list of what stops: the
--     plants that stop (private.billing_drops) are worked out on each read, as the
--     collecting plants past the booked room, picked plants first, then by link order.
--     So a removed login, a plant turned off, an upgrade or an undo needs no upkeep: a
--     kept plant gone makes the next linked one the pick; no booked change, no drops.
--   - api_billing_change, api_billing_extras, billing_book_change take p_keep (null: the
--     default pick, the first linked plants).
--   - Keep on a plant that stops puts it first in the pick; the last pick drops out.
--   - billing_renew fits the plants with the pick first, then books the plants it stopped
--     for deletion 30 days on, marked as the move to Free marks them (0133): only a start
--     brings one back. Removals due that day (Remove login) go at once, so the new date
--     does not put them off. billing_to_free keeps the first pick too.
--   - Starting a stopped plant while a downgrade is booked is allowed when the plan has
--     room now: it collects to the billing date, then stops unless picked. A new link still
--     links stopped once the booked plan is full (0127).
--   - api_link_status: drop per plant, and remove_on its deletion date (billing date + 30),
--     so Billing shows "Deleted <date>" and Keep. bill_change lists the plants that stop.
-- Lock order unchanged (0130): the user lock, then the billing row.
-- ============================================================================

alter table private.billing add column if not exists next_keep bigint[] not null default '{}';

-- The plants that stop on the billing date: collecting, not booked for deletion, past the
-- booked room, the pick first. Empty when nothing is booked.
create or replace function private.billing_drops(b private.billing)
returns bigint[] language sql stable set search_path = public, private, pg_temp as $$
  select coalesce(array_agg(plant_id order by plant_id), '{}') from (
    select pu.plant_id from public.plant_users pu
     where pu.user_id = b.user_id and not pu.paused and pu.plant_id <> all (coalesce(b.plants_to_remove, '{}'))
     order by array_position(b.next_keep, pu.plant_id) nulls last, pu.linked_at, pu.plant_id
    offset private.billing_next_room(b)) x
   where private.billing_next_room(b) is not null and not coalesce(b.comped, false)
$$;
revoke all on function private.billing_drops(private.billing) from public, anon, authenticated;

-- The pick as given: the user's collecting plants, in the order given, no repeats.
create or replace function private.billing_keep_list(p_user uuid, p_keep bigint[])
returns bigint[] language sql stable set search_path = public, private, pg_temp as $$
  select coalesce(array_agg(k order by i), '{}') from (
    select k, min(i) i from unnest(coalesce(p_keep, '{}')) with ordinality u(k, i)
     where exists (select 1 from public.plant_users where user_id = p_user and plant_id = k and not paused)
     group by k) x
$$;
revoke all on function private.billing_keep_list(uuid, bigint[]) from public, anon, authenticated;

-- 0129's fit, the pick ahead of link order.
drop function if exists private.billing_fit(uuid, bigint[]);
create or replace function private.billing_fit(p_user uuid, p_going bigint[], p_keep bigint[] default '{}')
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user;
  if coalesce(b.comped, false) then return; end if;
  update public.plant_users set paused = true
   where user_id = p_user and plant_id in (
     select plant_id from public.plant_users
      where user_id = p_user and not paused
      order by plant_id = any (p_going), array_position(p_keep, plant_id) nulls last, linked_at, plant_id
     offset public.billing_room(b.plan, b.extra_plants));
end $$;
revoke all on function private.billing_fit(uuid, bigint[], bigint[]) from public, anon, authenticated;

-- 0129's limit. A start under a booked downgrade is no longer refused: the plant collects
-- to the billing date, then stops unless picked (0136). A new link still links stopped.
create or replace function private.plant_users_plan_limit()
returns trigger language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  act int;
  kept int;
  why text;
begin
  if new.paused or (tg_op = 'UPDATE' and not old.paused) then return new; end if;
  -- A row already linked (the hourly sync's upsert): ON CONFLICT keeps its paused.
  if tg_op = 'INSERT' and exists (select 1 from public.plant_users where user_id = new.user_id and plant_id = new.plant_id) then
    return new;
  end if;
  perform private.billing_lock(new.user_id);
  -- after the lock: what the transaction before us committed
  select * into b from private.billing where user_id = new.user_id;
  if coalesce(b.comped, false) then return new; end if;
  select count(*), count(*) filter (where plant_id <> all (coalesce(b.plants_to_remove, '{}')))
    into act, kept
    from public.plant_users
   where user_id = new.user_id and not paused and plant_id <> new.plant_id;
  if act >= public.billing_room(b.plan, b.extra_plants) then
    why := 'no room';
  elsif tg_op = 'INSERT' and kept >= coalesce(private.billing_next_room(b), 2147483647) then
    why := 'plan change';
  else
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.paused := true;
    return new;
  end if;
  raise exception '%', why using errcode = '22023';
end $$;

-- 0130's renewal: the pick first; the plants it stops are deleted 30 days on (0136).
create or replace function public.billing_renew(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  due int;
  v_plan text; v_period text;
  going bigint[];
  keep bigint[];
  before bigint[];
  stopped bigint[];
  p bigint;
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' or b.comped then
    raise exception 'nothing to renew on Free' using errcode = '22023';
  end if;
  due := public.billing_amount_due(p_user);
  v_plan := coalesce(b.next_plan, b.plan);
  v_period := coalesce(b.next_period, b.period);
  going := case when b.remove_on <= b.next_billing_date then b.plants_to_remove else '{}' end;
  -- the plants the booked plan keeps: those that do not stop (0136)
  select coalesce(array_agg(plant_id order by array_position(b.next_keep, plant_id) nulls last, linked_at, plant_id), '{}')
    into keep from public.plant_users
   where user_id = p_user and not paused and plant_id <> all (coalesce(b.plants_to_remove, '{}'))
     and plant_id <> all (private.billing_drops(b));
  select coalesce(array_agg(plant_id), '{}') into before from public.plant_users where user_id = p_user and not paused;
  update private.billing
     set plan = v_plan,
         period = case when v_plan = 'free' then null else v_period end,
         billing_day = case when v_plan = 'free' then null else b.billing_day end,
         next_billing_date = case when v_plan = 'free' then null
                             else public.billing_step(b.next_billing_date, v_period, b.billing_day, 1) end,
         extra_plants = case when v_plan = 'family' then coalesce(b.next_extra_plants, b.extra_plants) else 0 end,
         next_plan = null, next_period = null, next_extra_plants = null, next_keep = '{}', updated_at = now()
   where user_id = p_user;
  -- booked for deletion last, then the pick
  perform private.billing_fit(p_user, coalesce(b.plants_to_remove, '{}'), keep);
  select coalesce(array_agg(plant_id order by plant_id), '{}') into stopped from public.plant_users
   where user_id = p_user and paused and plant_id = any (before) and plant_id <> all (coalesce(b.plants_to_remove, '{}'));
  -- stopped by the change: history deleted 30 days on, only a start keeps one (as 0133's Free)
  if cardinality(stopped) > 0 then
    -- removals due today (Remove login) go now, so the new date does not put them off
    if cardinality(going) > 0 then
      foreach p in array (select array_agg(x order by x) from unnest(going) x) loop
        perform private.billing_drop_plant(p_user, p);
      end loop;
      update private.billing
         set plants_to_remove = array(select x from unnest(plants_to_remove) x where x <> all (going)),
             free_removals = array(select x from unnest(free_removals) x where x <> all (going))
       where user_id = p_user;
    end if;
    update private.billing
       set plants_to_remove = array(select distinct x from unnest(plants_to_remove || stopped) x order by x),
           free_removals = array(select distinct x from unnest(free_removals || stopped) x order by x),
           remove_on = b.next_billing_date + 30, updated_at = now()
     where user_id = p_user;
  end if;
  return jsonb_build_object('charge', due, 'plan', v_plan, 'removePlants', to_jsonb(going), 'stopped', to_jsonb(stopped));
end $$;

-- 0133's move to Free, the first pick kept (0136).
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
  -- a kept plant that was stopped (its readings wiped) refetches them, as every start does (0131)
  if exists (select 1 from public.plant_users where user_id = p_user and plant_id = keep and paused)
     and not exists (select 1 from public.plant_users where plant_id = keep and not paused) then
    update public.plant_users set paused = false where user_id = p_user and plant_id = keep;
    perform private.plant_start_fill(keep);
  else
    update public.plant_users set paused = false where user_id = p_user and plant_id = keep and paused;
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

-- 0130's booking, with the pick in place of "remove plants first" (0136).
drop function if exists public.billing_book_change(uuid, text, text);
create or replace function public.billing_book_change(p_user uuid, p_plan text, p_period text default null,
  p_keep bigint[] default null)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  rank constant jsonb := '{"free": 0, "home": 1, "family": 2}';
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' then
    raise exception 'nothing to change on Free' using errcode = '22023';
  end if;
  if b.comped then
    raise exception 'this plan is free of charge' using errcode = '22023';
  end if;
  if (rank->>p_plan)::int > (rank->>b.plan)::int then
    raise exception 'an upgrade starts at once, not at the billing date' using errcode = '22023';
  end if;
  update private.billing
     set next_plan   = case when p_plan = b.plan then null else p_plan end,
         next_period = case when p_plan = 'free' or coalesce(p_period, b.period) = b.period then null
                            else p_period end,
         -- a new plan: the pick given (none: the first linked); a period switch or undo: the pick held
         next_keep   = case when p_plan = b.plan and p_keep is null then case when b.next_extra_plants is null then '{}' else next_keep end
                            else private.billing_keep_list(p_user, p_keep) end,
         updated_at  = now()
   where user_id = p_user;
end $$;
revoke all on function public.billing_book_change(uuid, text, text, bigint[]) from public, anon, authenticated;
grant execute on function public.billing_book_change(uuid, text, text, bigint[]) to service_role;

-- 0134's change, with the pick; bill_change lists the plants that stop (0136).
drop function if exists public.api_billing_change(text, text);
create or replace function public.api_billing_change(p_plan text, p_period text default null, p_keep bigint[] default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing; was_booked boolean; drops bigint[];
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  -- for update: a double tap undoes once and emails once
  select next_plan is not null or next_period is not null into was_booked from private.billing where user_id = auth.uid() for update;
  perform public.billing_book_change(auth.uid(), p_plan, p_period, p_keep);
  select * into b from private.billing where user_id = auth.uid();
  drops := private.billing_drops(b);
  if b.next_plan is not null or b.next_period is not null then
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (auth.uid(), 'bill_change', 'bill_change:' || gen_random_uuid(),
            jsonb_build_object('from', b.plan, 'to', coalesce(b.next_plan, b.plan),
              'fromPeriod', b.period, 'toPeriod', coalesce(b.next_period, b.period), 'on', b.next_billing_date,
              'nextAmount', case when coalesce(b.next_plan, b.plan) <> 'free' then public.billing_amount_due(auth.uid()) end,
              'deleteOn', case when cardinality(drops) > 0 then b.next_billing_date + 30 end,
              'removePlants', coalesce((select jsonb_agg(pu.plant_name order by pu.linked_at) from public.plant_users pu
                                         where pu.user_id = auth.uid() and pu.plant_id = any (drops)), '[]'::jsonb)),
            1);
  elsif was_booked then
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (auth.uid(), 'bill_kept', 'bill_kept:' || gen_random_uuid(),
            jsonb_build_object('plan', b.plan, 'period', b.period, 'on', b.next_billing_date,
              'nextAmount', public.billing_amount_due(auth.uid())),
            1);
  end if;
  return public.api_billing_status();
end $$;
revoke all on function public.api_billing_change(text, text, bigint[]) from public, anon;
grant execute on function public.api_billing_change(text, text, bigint[]) to authenticated, service_role;

-- 0130's extras, with the pick in place of "remove plants first" (0136).
drop function if exists public.api_billing_extras(int);
create or replace function public.api_billing_extras(p_count int, p_keep bigint[] default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(auth.uid());
  select * into b from private.billing where user_id = auth.uid() for update;
  if b.plan is distinct from 'family' or b.comped then
    raise exception 'extra plants are on Family only' using errcode = '22023';
  end if;
  if p_count is null or p_count < 0 or p_count > b.extra_plants then
    raise exception 'pay to add extra plants' using errcode = '22023';
  end if;
  if b.next_plan is not null and p_count <> b.extra_plants then
    raise exception 'plan change' using errcode = '22023';
  end if;
  update private.billing
     set next_extra_plants = case when p_count = extra_plants then null else p_count end,
         next_keep = case when p_count = extra_plants and next_plan is null then '{}'
                          when p_count = extra_plants then next_keep
                          else private.billing_keep_list(auth.uid(), p_keep) end,
         updated_at = now()
   where user_id = auth.uid();
  return public.api_billing_status();
end $$;
revoke all on function public.api_billing_extras(int, bigint[]) from public, anon;
grant execute on function public.api_billing_extras(int, bigint[]) to authenticated, service_role;

-- 0133's keep. A plant that stops on the billing date goes first in the pick; on a full
-- booked plan the last pick drops out (0136).
create or replace function public.api_billing_keep(p_plant bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  picks bigint[];
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(auth.uid());
  select * into b from private.billing where user_id = auth.uid() for update;
  if p_plant = any (private.billing_drops(b)) then
    select coalesce(array_agg(plant_id order by array_position(b.next_keep, plant_id) nulls last, linked_at, plant_id), '{}')
      into picks from public.plant_users
     where user_id = auth.uid() and not paused and plant_id <> all (coalesce(b.plants_to_remove, '{}'))
       and plant_id <> all (private.billing_drops(b));
    update private.billing
       set next_keep = (array[p_plant] || picks)[1:private.billing_next_room(b)], updated_at = now()
     where user_id = auth.uid();
    return public.api_billing_status();
  end if;
  -- Free: a stopped plant comes back only by swapping it in (api_plant_start), never by Keep (0131).
  if coalesce(b.plan, 'free') = 'free'
     or (p_plant = any (coalesce(b.free_removals, '{}')) and p_plant = any (b.plants_to_remove)) then
    raise exception 'start it instead' using errcode = '22023';  -- only a start keeps it (0133)
  end if;
  if (select count(*) from public.plant_users
       where user_id = auth.uid() and not paused
         and (plant_id = p_plant or plant_id <> all (b.plants_to_remove)))
     > coalesce(private.billing_next_room(b), 2147483647) then
    raise exception 'needed for your plan change' using errcode = '22023';
  end if;
  update private.billing
     set plants_to_remove = array_remove(plants_to_remove, p_plant),
         remove_on = case when array_remove(plants_to_remove, p_plant) = '{}' then null else remove_on end,
         updated_at = now()
   where user_id = auth.uid();
  return public.api_billing_status();
end $$;

-- 0133's link status: a plant that stops on the billing date says so (drop), with its
-- deletion date in remove_on (0136).
CREATE OR REPLACE FUNCTION public.api_link_status()
 RETURNS TABLE(account_id uuid, sunsynk_username text, status text, linked_at timestamp with time zone, last_ok_at timestamp with time zone, plants jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with b as (select bl.*, private.billing_drops(bl) drops from private.billing bl where bl.user_id = auth.uid())
  select a.id, a.sunsynk_username, a.status, a.linked_at, a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name,
                                                        'paused', pu.paused,
                                                        'inverters', (select count(*) from private.inverters i where i.plant_id = pu.plant_id),
                                                        'remove_on', case when pu.plant_id = any (b.plants_to_remove) then b.remove_on
                                                                          when pu.plant_id = any (b.drops) then b.next_billing_date + 30 end,
                                                        -- collects to the billing date, then stops (0136)
                                                        'drop', coalesce(pu.plant_id = any (b.drops), false),
                                                        -- booked by the move to Free: kept only by starting it (0133)
                                                        'free_removal', pu.plant_id = any (b.plants_to_remove) and pu.plant_id = any (b.free_removals))
                                    order by pu.linked_at, pu.plant_id)
                     from public.plant_users pu
                     left join b on b.user_id = pu.user_id
                    where pu.account_id = a.id and pu.user_id = auth.uid()),
                  '[]'::jsonb)
    from private.sunsynk_accounts a
   where a.user_id = auth.uid()
   order by a.linked_at desc
$function$;
revoke all on function public.api_link_status() from public, anon;
grant execute on function public.api_link_status() to authenticated, service_role;
