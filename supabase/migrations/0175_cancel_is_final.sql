-- SOLAR-457: a booked cancel is final, and a paid switch to yearly can be cancelled.
-- Decided by Brynne 2026-11-10: cancel is always offered. Once booked it stays: no undo, no
-- downgrade, upgrade or extras until the plan ends; then the user starts again from Free.
-- During a paid switch to yearly (0138, prepaid_on) a cancel is booked for the end of that
-- year: on the billing date the plan turns yearly as paid, and it ends a year later. No refund.

-- 0138's guard, with the cancel kept. Every path that changes the row meets here.
create or replace function private.billing_year_paid_guard()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  if new.plan = 'free' or new.comped then
    new.prepaid_on := null;
    return new;
  end if;
  if old.next_plan = 'free' and new.next_plan is distinct from 'free' then
    raise exception 'your plan is cancelled: it ends on its date' using errcode = '22023';
  end if;
  -- a paid year: only a cancel may be booked until it starts
  if old.prepaid_on is not null and new.prepaid_on is not null
     and ((new.plan, new.period, new.extra_plants, new.next_period, new.next_extra_plants)
            is distinct from (old.plan, old.period, old.extra_plants, old.next_period, old.next_extra_plants)
          or (new.next_plan is distinct from old.next_plan and new.next_plan is distinct from 'free')) then
    raise exception 'your year is paid: the plan stays until it starts' using errcode = '22023';
  end if;
  return new;
end $$;

-- A cancelled plan buys nothing more: no upgrade, no switch to yearly.
create or replace function private.billing_charge_cancel_guard()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  if new.kind in ('upgrade', 'switch')
     and exists (select 1 from private.billing where user_id = new.user_id and plan <> 'free' and next_plan = 'free') then
    raise exception 'your plan is cancelled: it ends on its date' using errcode = '22023';
  end if;
  return new;
end $$;
drop trigger if exists billing_charge_cancel_guard on private.billing_charges;
create trigger billing_charge_cancel_guard before insert on private.billing_charges
  for each row execute function private.billing_charge_cancel_guard();

-- 0136's drops: none while a paid year waits to start; the plants that stop are known once
-- the year has started and the cancel's date is set.
create or replace function private.billing_drops(b private.billing)
returns bigint[] language sql stable set search_path = public, private, pg_temp as $$
  select coalesce(array_agg(plant_id order by plant_id), '{}') from (
    select pu.plant_id from public.plant_users pu
     where pu.user_id = b.user_id and not pu.paused and pu.plant_id <> all (coalesce(b.plants_to_remove, '{}'))
     order by array_position(b.next_keep, pu.plant_id) nulls last, pu.linked_at, pu.plant_id
    offset private.billing_next_room(b)) x
   where private.billing_next_room(b) is not null and not coalesce(b.comped, false) and b.prepaid_on is null
$$;

-- 0155's booking: a cancel is final; in a paid year only a cancel, which keeps the switch.
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
  if b.next_plan = 'free' then
    raise exception 'your plan is cancelled: it ends on its date' using errcode = '22023';
  end if;
  if b.prepaid_on is not null then
    if p_plan <> 'free' then
      raise exception 'your year is paid: the plan stays until it starts' using errcode = '22023';
    end if;
    update private.billing
       set next_plan = 'free', next_keep = private.billing_keep_list(p_user, p_keep), updated_at = now()
     where user_id = p_user;
    return;
  end if;
  if (rank->>p_plan)::int > (rank->>b.plan)::int then
    raise exception 'an upgrade starts at once, not at the billing date' using errcode = '22023';
  end if;
  if p_plan = b.plan and b.period = 'monthly' and p_period = 'yearly' then
    raise exception 'a switch to yearly is paid now, not booked' using errcode = '22023';
  end if;
  update private.billing
     set next_plan   = case when p_plan = b.plan then null else p_plan end,
         next_period = case when p_plan = 'free' or coalesce(p_period, b.period) = b.period then null
                            else p_period end,
         -- a new plan: the pick given (none: the first linked); a period switch or undo: the pick held
         -- a plan change or an undo takes a booked extras drop with it: one change (SOLAR-364)
         next_extra_plants = case when p_plan <> b.plan or coalesce(p_period, b.period) = b.period then null
                                  else next_extra_plants end,
         next_keep   = case when p_plan = b.plan and p_keep is null
                              then case when coalesce(p_period, b.period) = b.period or b.next_extra_plants is null then '{}' else next_keep end
                            else private.billing_keep_list(p_user, p_keep) end,
         updated_at  = now()
   where user_id = p_user;
end $$;

-- 0138's renewal: a cancel booked in a paid year starts that year first.
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
  -- a switch paid this date's year already (0138)
  due := case when b.prepaid_on = b.next_billing_date then 0 else public.billing_amount_due(p_user) end;
  -- A cancel booked in a paid year (SOLAR-457): the year starts as paid; the cancel waits for its end.
  if b.prepaid_on = b.next_billing_date and b.next_plan = 'free' then
    update private.billing
       set period = 'yearly',
           next_billing_date = public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1),
           extra_plants = case when b.plan = 'family' then coalesce(b.next_extra_plants, b.extra_plants) else 0 end,
           next_period = null, next_extra_plants = null, prepaid_on = null, updated_at = now()
     where user_id = p_user;
    return jsonb_build_object('charge', 0, 'plan', b.plan, 'removePlants', '[]'::jsonb, 'stopped', '[]'::jsonb);
  end if;
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
         next_plan = null, next_period = null, next_extra_plants = null, next_keep = '{}', prepaid_on = null,
         updated_at = now()
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


-- 0155's stale check: a cancelled plan takes no upgrade or switch.
create or replace function private.billing_charge_stale(c private.billing_charges, b private.billing, p_day date default null)
returns text language plpgsql stable set search_path = public, private, pg_temp as $$
declare q jsonb;
begin
  if c.kind in ('renewal', 'settle') then
    if b.state = 'past_due' and c.due_on = b.past_due_since then return null; end if;
    if c.kind = 'renewal' and c.status = 'pending' and b.state = 'active' and b.plan <> 'free' and not b.comped
       and c.due_on = public.billing_step(b.next_billing_date, b.period, b.billing_day, -1)
       and not exists (select 1 from private.billing_charges x
                        where x.user_id = c.user_id and x.kind in ('renewal', 'settle') and x.due_on = c.due_on
                          and x.status = 'paid' and x.error is null and x.reference <> c.reference) then
      return null;
    end if;
    return 'not due';
  end if;
  -- A paid year changes nothing more until it starts; a second switch paid goes back.
  if b.prepaid_on is not null then return 'year paid'; end if;
  -- a booked cancel is final (SOLAR-457): a payment made after it goes back
  if b.next_plan = 'free' and c.kind in ('upgrade', 'switch') then return 'plan cancelled'; end if;
  if c.kind = 'switch' then
    if b.plan is distinct from c.plan or b.period is distinct from 'monthly' or b.state = 'past_due' or b.comped then
      return 'plan changed';
    end if;
    if b.next_plan is not null then return 'plan change booked'; end if;
    if c.billing_date is distinct from b.next_billing_date then return 'billing date passed'; end if;
    q := public.billing_upgrade_quote(c.user_id, c.plan, 0, 'yearly');
    if (q->>'dueNow')::int <> c.amount then return 'price changed'; end if;
    return null;
  end if;
  if c.kind = 'start' and coalesce(b.plan, 'free') <> 'free' then return 'not on Free'; end if;
  -- a bigger plan yearly from a monthly plan changes the period (SOLAR-364)
  if c.kind = 'upgrade' and (coalesce(b.plan, 'free') = 'free' or b.state = 'past_due'
      or (b.period is distinct from c.period and not (b.period = 'monthly' and c.period = 'yearly' and b.plan <> c.plan))) then
    return 'plan changed';
  end if;
  if c.billing_date is distinct from b.next_billing_date then return 'billing date passed'; end if;
  if c.added > 0 and b.next_plan is not null and c.plan = b.plan then return 'plan change booked'; end if;
  if c.extra_plants is distinct from
     (case when c.plan = 'family' then case when b.plan = 'family' then b.extra_plants else 0 end + c.added else 0 end) then
    return 'extra plants changed';
  end if;
  begin
    q := public.billing_upgrade_quote(c.user_id, c.plan, c.added,
                                      case when c.kind = 'start' or c.period is distinct from b.period then c.period end,
                                      coalesce(p_day, private.billing_today()),
                                      case when c.kind = 'start' then coalesce(c.offer_id, '') end);
  exception when sqlstate '22023' then
    return 'not an upgrade';
  end;
  if greatest((q->>'dueNow')::int, 0) <> c.amount then return 'price changed'; end if;
  return null;
end $$;


-- 0136's change: a cancel in a paid year is emailed with the end of that year.
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
              'fromPeriod', b.period, 'toPeriod', coalesce(b.next_period, b.period),
              -- a cancel in a paid year ends when that year does (SOLAR-457)
              'on', case when b.prepaid_on is not null then public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1)
                         else b.next_billing_date end,
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

