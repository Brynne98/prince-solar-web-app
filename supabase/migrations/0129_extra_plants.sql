-- ============================================================================
-- 0129 — Family buys room for extra plants, at R49 a plant (SOLAR-264, decided by
-- Brynne and plan approved 2026-10-31).
--
-- Family covers 3 plants. Each plant past the 3rd is R49 a month (R588 a year), per
-- plant, not per inverter. The room is bought on its own, apart from logins:
-- private.billing.extra_plants is the number paid for. The bill is Family plus that
-- many extras, however many plants collect.
--   - Raising it is a charge (billing_charge_open with p_extra, the new total): today's
--     share up to the billing date, then every renewal. Paid, stopped plants start into
--     the new room, oldest first.
--   - Lowering it waits for the billing date (api_billing_extras books
--     next_extra_plants). It can't go below the plants past the 3rd that collect now,
--     plants booked for removal left out: stop or remove plants first.
--   - Linking only fills the room there is: the plant_users trigger links the rest
--     stopped. No cost question at link time any more.
-- Room: Free and Home 1, Family 3 + extra_plants, comped no limit. A booked change
-- (plan or extras) also caps new starts at the booked room.
--
-- Family accounts from before this keep what they collect: extra_plants is set to
-- their plants past the 3rd.
-- ============================================================================

alter table private.billing add column if not exists extra_plants int not null default 0 check (extra_plants >= 0);
alter table private.billing add column if not exists next_extra_plants int check (next_extra_plants >= 0);
-- the total extra_plants a start or upgrade charge pays for
alter table private.billing_charges add column if not exists extra_plants int;

-- Plants booked for removal leave on their date, so they are not paid for after it.
update private.billing b
   set extra_plants = greatest((select count(*) from public.plant_users pu
                                 where pu.user_id = b.user_id and not pu.paused
                                   and pu.plant_id <> all (b.plants_to_remove)) - 3, 0)
 where b.plan = 'family' and not b.comped;

-- Charges still open from before this were priced per inverter: they no longer fit.
update private.billing_charges set extra_plants = -1
 where status = 'pending' and kind in ('start', 'upgrade') and extra_plants is null;

-- ---------------------------------------------------------------------------
-- 1. Room
-- ---------------------------------------------------------------------------
-- How many plants a plan with this many extras collects.
create or replace function public.billing_room(p_plan text, p_extra int default 0)
returns int language sql immutable as $$
  select case coalesce(p_plan, 'free') when 'family' then 3 + greatest(coalesce(p_extra, 0), 0) else 1 end
$$;
revoke all on function public.billing_room(text, int) from public, anon;
grant execute on function public.billing_room(text, int) to authenticated, service_role;

-- The room once a booked change lands; null when nothing is booked.
create or replace function private.billing_next_room(b private.billing)
returns int language sql immutable as $$
  select case when b.next_plan is null and b.next_extra_plants is null then null
              else public.billing_room(coalesce(b.next_plan, b.plan), coalesce(b.next_extra_plants, b.extra_plants)) end
$$;
revoke all on function private.billing_next_room(private.billing) from public, anon, authenticated;

-- 0127's trigger, on room in place of the 3-plant limit and paid starts.
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
  elsif kept >= coalesce(private.billing_next_room(b), 2147483647) then
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

-- 0127's fit, to the room of the plan the renewal left.
create or replace function private.billing_fit(p_user uuid, p_going bigint[])
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
      order by plant_id = any (p_going), linked_at, plant_id
     offset public.billing_room(b.plan, b.extra_plants));
end $$;

-- 0127's link check: room, not inverters. p_plant_inverters is read for its length only.
create or replace function public.billing_may_link(p_user uuid, p_sunsynk_username text, p_plant_inverters int[])
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  have int := (select count(*) from public.plant_users where user_id = p_user and not paused);
begin
  select * into b from private.billing where user_id = p_user;
  if coalesce(b.comped, false) then
    return jsonb_build_object('ok', true, 'plan', b.plan, 'comped', true);
  end if;
  if have + coalesce(cardinality(p_plant_inverters), 0) > public.billing_room(b.plan, b.extra_plants) then
    return jsonb_build_object('ok', false, 'plan', coalesce(b.plan, 'free'), 'reason', 'upgrade_needed');
  end if;
  return jsonb_build_object('ok', true, 'plan', coalesce(b.plan, 'free'));
end $$;

-- 0127's booking: the room of the booked plan, with the extras held or booked.
create or replace function public.billing_book_change(p_user uuid, p_plan text, p_period text default null)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  rank constant jsonb := '{"free": 0, "home": 1, "family": 2}';
  keep int;
begin
  select * into b from private.billing where user_id = p_user for update;
  perform private.billing_lock(p_user);
  if b.plan is null or b.plan = 'free' then
    raise exception 'nothing to change on Free' using errcode = '22023';
  end if;
  if b.comped then
    raise exception 'this plan is free of charge' using errcode = '22023';
  end if;
  if (rank->>p_plan)::int > (rank->>b.plan)::int then
    raise exception 'an upgrade starts at once, not at the billing date' using errcode = '22023';
  end if;
  keep := (select count(*) from public.plant_users
            where user_id = p_user and not paused and plant_id <> all (b.plants_to_remove));
  if keep > public.billing_room(p_plan, coalesce(b.next_extra_plants, b.extra_plants)) then
    raise exception 'remove plants first' using errcode = '22023';
  end if;
  update private.billing
     set next_plan   = case when p_plan = b.plan then null else p_plan end,
         next_period = case when p_plan = 'free' or coalesce(p_period, b.period) = b.period then null
                            else p_period end,
         updated_at  = now()
   where user_id = p_user;
end $$;

-- 0127's keep, against the booked room.
create or replace function public.api_billing_keep(p_plant bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid() for update;
  perform private.billing_lock(auth.uid());
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

-- Lower the extra plants from the billing date, or undo a booked lowering (p_count =
-- the extras held). Raising is a charge: billing/pay.
create or replace function public.api_billing_extras(p_count int)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  keep int;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid() for update;
  perform private.billing_lock(auth.uid());
  if b.plan is distinct from 'family' or b.comped then
    raise exception 'extra plants are on Family only' using errcode = '22023';
  end if;
  if p_count is null or p_count < 0 or p_count > b.extra_plants then
    raise exception 'pay to add extra plants' using errcode = '22023';
  end if;
  if b.next_plan is not null and p_count <> b.extra_plants then
    raise exception 'plan change' using errcode = '22023';
  end if;
  keep := (select count(*) from public.plant_users
            where user_id = auth.uid() and not paused and plant_id <> all (b.plants_to_remove));
  if keep > public.billing_room('family', p_count) then
    raise exception 'remove plants first' using errcode = '22023';
  end if;
  update private.billing
     set next_extra_plants = case when p_count = extra_plants then null else p_count end, updated_at = now()
   where user_id = auth.uid();
  return public.api_billing_status();
end $$;

-- ---------------------------------------------------------------------------
-- 2. Prices
-- ---------------------------------------------------------------------------
-- 0110's next bill: the plan and extras that run from the billing date.
create or replace function public.billing_amount_due(p_user uuid)
returns int language sql stable security definer set search_path = public, private, pg_temp as $$
  select coalesce((
    select public.billing_amount(coalesce(b.next_plan, b.plan), coalesce(b.next_period, b.period),
             coalesce(b.next_extra_plants, b.extra_plants))
      from private.billing b
     where b.user_id = p_user and b.plan <> 'free' and not b.comped and coalesce(b.next_plan, b.plan) <> 'free'), 0)
$$;

-- 0110's quote. p_added: extra plants bought on top of those held (Family only).
create or replace function public.billing_upgrade_quote(
  p_user uuid, p_plan text, p_added int default 0, p_period text default null,
  p_today date default (now() at time zone 'Africa/Johannesburg')::date)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  extra int;
  v_add int := case when p_plan = 'family' then greatest(coalesce(p_added, 0), 0) else 0 end;
  old_amt int; new_amt int; nxt date;
begin
  select * into b from private.billing where user_id = p_user;
  if b.plan is null or b.plan = 'free' then
    if p_plan = 'free' or p_period is null then
      raise exception 'upgrade from Free needs a paid plan and a period' using errcode = '22023';
    end if;
    new_amt := public.billing_amount(p_plan, p_period, v_add);
    nxt := public.billing_step(p_today, p_period, extract(day from p_today)::int, 1);
    return jsonb_build_object('dueNow', new_amt, 'nextCharge', new_amt, 'nextDate', nxt);
  end if;
  if (p_plan = 'home' and b.plan = 'family') or p_plan = 'free' then
    raise exception 'not an upgrade' using errcode = '22023';
  end if;
  extra := case when b.plan = 'family' then b.extra_plants else 0 end;
  old_amt := public.billing_amount(b.plan, b.period, extra);
  new_amt := public.billing_amount(p_plan, b.period, extra + v_add);
  return jsonb_build_object(
    'dueNow', public.billing_prorate(new_amt - old_amt, p_today,
                public.billing_step(b.next_billing_date, b.period, b.billing_day, -1),
                b.next_billing_date),
    'nextCharge', new_amt,
    'nextDate', b.next_billing_date);
end $$;

-- The extras a charge buys: p_extra, the total wanted on Family, less those held.
create or replace function private.billing_extra_added(b private.billing, p_plan text, p_extra int)
returns int language sql immutable as $$
  select case when p_plan <> 'family' then 0
              else greatest(coalesce(p_extra, 0) - case when b.plan = 'family' then b.extra_plants else 0 end, 0) end
$$;
revoke all on function private.billing_extra_added(private.billing, text, int) from public, anon, authenticated;

-- The paywall and plans page figures. p_extra: the extra plants wanted on Family in all;
-- null keeps those held.
drop function if exists public.api_billing_quote(text, text, int, bigint[]);
create or replace function public.api_billing_quote(p_plan text, p_period text default 'monthly', p_extra int default null)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid();
  return jsonb_build_object('plan', coalesce(b.plan, 'free'), 'period', b.period,
           'extraPlants', coalesce(b.extra_plants, 0),
           'extraPrice', public.billing_amount('family', coalesce(b.period, p_period), 1)
                         - public.billing_amount('family', coalesce(b.period, p_period), 0))
      || public.billing_upgrade_quote(auth.uid(), p_plan,
           private.billing_extra_added(b, p_plan, coalesce(p_extra, b.extra_plants)),
           case when coalesce(b.plan, 'free') = 'free' then p_period end);
end $$;
revoke all on function public.api_billing_quote(text, text, int) from public, anon;
grant execute on function public.api_billing_quote(text, text, int) to authenticated, service_role;

-- 0120's status, with the extras held and booked.
create or replace function public.api_billing_status()
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid();
  return jsonb_build_object(
    'plan', coalesce(b.plan, 'free'), 'period', b.period, 'state', coalesce(b.state, 'active'),
    'comped', coalesce(b.comped, false),
    'nextDate', b.next_billing_date,
    'nextAmount', public.billing_amount_due(auth.uid()),
    'price', public.billing_amount(coalesce(b.plan, 'free'), b.period, coalesce(b.extra_plants, 0)),
    'extraPlants', coalesce(b.extra_plants, 0), 'nextExtraPlants', b.next_extra_plants,
    'nextPlan', b.next_plan, 'nextPeriod', b.next_period,
    'removeOn', b.remove_on,
    'removePlants', coalesce((select jsonb_agg(jsonb_build_object('id', pu.plant_id, 'name', pu.plant_name) order by pu.linked_at)
                                from public.plant_users pu
                               where pu.user_id = auth.uid() and pu.plant_id = any (coalesce(b.plants_to_remove, '{}'))), '[]'::jsonb),
    -- No authorization code: only what the page shows.
    'card', case when b.card is not null then jsonb_build_object(
              'name', initcap(trim(coalesce(nullif(trim(b.card->>'card_type'), ''), b.card->>'brand', 'card'))),
              'brand', lower(trim(coalesce(nullif(trim(b.card->>'card_type'), ''), b.card->>'brand', 'card'))),
              'last4', b.card->>'last4', 'expMonth', b.card->>'exp_month', 'expYear', b.card->>'exp_year') end,
    -- Money taken and kept: not the R1 card checks, not payments refunded by hand.
    'payments', coalesce((select jsonb_agg(p order by p->>'at' desc) from (
                  select jsonb_build_object('at', c.settled_at, 'date', (c.settled_at at time zone 'Africa/Johannesburg')::date,
                           'kind', c.kind, 'plan', c.plan, 'period', c.period, 'amount', c.amount) p
                    from private.billing_charges c
                   where c.user_id = auth.uid() and c.status = 'paid' and c.kind <> 'card' and c.amount > 0
                     and c.error is null
                   order by c.settled_at desc limit 6) x), '[]'::jsonb),
    'prices', jsonb_build_object(
      'monthly', jsonb_build_object('home', public.billing_amount('home', 'monthly'), 'family', public.billing_amount('family', 'monthly'),
                   'extra', public.billing_amount('family', 'monthly', 1) - public.billing_amount('family', 'monthly')),
      'yearly', jsonb_build_object('home', public.billing_amount('home', 'yearly'), 'family', public.billing_amount('family', 'yearly'),
                   'extra', public.billing_amount('family', 'yearly', 1) - public.billing_amount('family', 'yearly'))));
end $$;

-- ---------------------------------------------------------------------------
-- 3. Plan changes on the billing date
-- ---------------------------------------------------------------------------
-- 0127's renewal: the booked extras land too; off Family there are none.
create or replace function public.billing_renew(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  due int;
  v_plan text; v_period text;
  going bigint[];
begin
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' or b.comped then
    raise exception 'nothing to renew on Free' using errcode = '22023';
  end if;
  due := public.billing_amount_due(p_user);
  v_plan := coalesce(b.next_plan, b.plan);
  v_period := coalesce(b.next_period, b.period);
  going := case when b.remove_on <= b.next_billing_date then b.plants_to_remove else '{}' end;
  update private.billing
     set plan = v_plan,
         period = case when v_plan = 'free' then null else v_period end,
         billing_day = case when v_plan = 'free' then null else b.billing_day end,
         next_billing_date = case when v_plan = 'free' then null
                             else public.billing_step(b.next_billing_date, v_period, b.billing_day, 1) end,
         extra_plants = case when v_plan = 'family' then coalesce(b.next_extra_plants, b.extra_plants) else 0 end,
         next_plan = null, next_period = null, next_extra_plants = null, updated_at = now()
   where user_id = p_user;
  perform private.billing_fit(p_user, going);
  return jsonb_build_object('charge', due, 'plan', v_plan, 'removePlants', to_jsonb(going));
end $$;

-- 0127's move to Free when unpaid: no extras on Free.
create or replace function private.billing_to_free(p_user uuid, p_today date)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  keep bigint;
  stop bigint[];
begin
  select * into b from private.billing where user_id = p_user for update;
  select plant_id into keep from public.plant_users where user_id = p_user
   order by linked_at, plant_id limit 1;
  select coalesce(array_agg(plant_id order by plant_id), '{}') into stop
    from public.plant_users where user_id = p_user and plant_id is distinct from keep;
  update private.billing
     set plan = 'free', period = null, billing_day = null, next_billing_date = null,
         next_plan = null, next_period = null, extra_plants = 0, next_extra_plants = null,
         state = 'active', past_due_since = null,
         plants_to_remove = array(select distinct x from unnest(plants_to_remove || stop) x order by x),
         remove_on = case when cardinality(stop) > 0 then p_today + 30 else remove_on end,
         updated_at = now()
   where user_id = p_user;
  update public.plant_users set paused = true where user_id = p_user and plant_id is distinct from keep and not paused;
  update public.plant_users set paused = false where user_id = p_user and plant_id = keep and paused;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (p_user, 'bill_free', 'bill_free:' || p_today,
          jsonb_build_object('from', b.plan, 'deleteOn', p_today + 30,
            'kept', coalesce((select plant_name from public.plant_users where user_id = p_user and plant_id = keep), ''),
            'stopped', coalesce((select jsonb_agg(plant_name order by linked_at) from public.plant_users
                                  where user_id = p_user and plant_id = any (stop)), '[]'::jsonb)),
          1)
  on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Charges
-- ---------------------------------------------------------------------------
-- 0127's open. p_extra: the extra plants wanted on Family in all; null keeps those held.
drop function if exists public.billing_charge_open(uuid, text, text, bigint[]);
create or replace function public.billing_charge_open(
  p_user uuid, p_plan text, p_period text default null, p_extra int default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  q jsonb;
  ref text := 'psh_' || replace(gen_random_uuid()::text, '-', '');
  v_kind text;
  v_period text;
  added int;
  today date := private.billing_today();
begin
  select * into b from private.billing where user_id = p_user for update;
  perform private.billing_lock(p_user);
  if b.comped then raise exception 'this plan is free of charge' using errcode = '22023'; end if;
  if b.state = 'past_due' then raise exception 'settle the failed payment first' using errcode = '22023'; end if;
  v_kind := case when coalesce(b.plan, 'free') = 'free' then 'start' else 'upgrade' end;
  v_period := case when v_kind = 'start' then coalesce(p_period, 'monthly') else b.period end;
  if v_period not in ('monthly', 'yearly') or p_plan not in ('home', 'family') then
    raise exception 'unknown plan or period' using errcode = '22023';
  end if;
  if p_extra < 0 then raise exception 'unknown plan or period' using errcode = '22023'; end if;
  added := private.billing_extra_added(b, p_plan, coalesce(p_extra, b.extra_plants));
  if v_kind = 'upgrade' and p_plan = b.plan then
    -- Same plan: only more extra plants are something to buy.
    if added = 0 then raise exception 'nothing to buy' using errcode = '22023'; end if;
    -- A downgrade or cancel is booked: the booked plan has no room for them.
    if b.next_plan is not null then raise exception 'plan change' using errcode = '22023'; end if;
  end if;
  q := public.billing_upgrade_quote(p_user, p_plan, added, case when v_kind = 'start' then v_period end, today);
  insert into private.billing_charges (reference, user_id, kind, plan, period, added, extra_plants, amount, due_on, created_on, billing_date)
  values (ref, p_user, v_kind, p_plan, v_period, added,
          case when p_plan = 'family' then case when b.plan = 'family' then b.extra_plants else 0 end + added else 0 end,
          greatest((q->>'dueNow')::int, 0), today, today, b.next_billing_date);
  if (q->>'dueNow')::int <= 0 then
    -- Nothing to take: applied now, or refused (nothing charged, so nothing to refund).
    if (public.billing_charge_paid(ref, null, true)->>'applied') = 'false' then
      raise exception 'nothing changed' using errcode = '22023';
    end if;
    return jsonb_build_object('amount', 0, 'reference', ref);
  end if;
  return jsonb_build_object('reference', ref, 'amount', (q->>'dueNow')::int,
    'email', (select email from auth.users where id = p_user),
    'card', b.card->>'authorization_code',
    -- Paystack charges a saved card only with the email it was saved with.
    'cardEmail', coalesce(b.card_email, (select email from auth.users where id = p_user)));
end $$;
revoke all on function public.billing_charge_open(uuid, text, text, int) from public, anon, authenticated;
grant execute on function public.billing_charge_open(uuid, text, text, int) to service_role;

-- 0127's resume: stopped plants start into the room, oldest first, until it is full.
create or replace function private.billing_resume(p_user uuid, p_plants bigint[])
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  r record;
  others boolean;
begin
  for r in select pu.plant_id from public.plant_users pu
            where pu.user_id = p_user and pu.paused and (p_plants is null or pu.plant_id = any (p_plants))
            order by pu.linked_at, pu.plant_id loop
    others := exists (select 1 from public.plant_users where plant_id = r.plant_id and not paused);
    begin
      update public.plant_users set paused = false where user_id = p_user and plant_id = r.plant_id;
    exception when sqlstate '22023' then
      exit;  -- the room is full
    end;
    if not others then perform private.plant_start_fill(r.plant_id); end if;
    -- A plant stopped by a move to Free and now resumed is no longer up for deletion;
    -- the ones still paused stay booked. At once, so the next plant's check counts it kept.
    update private.billing
       set plants_to_remove = array_remove(plants_to_remove, r.plant_id),
           remove_on = case when array_remove(plants_to_remove, r.plant_id) = '{}' then null else remove_on end
     where user_id = p_user and r.plant_id = any (plants_to_remove);
  end loop;
end $$;
revoke all on function private.billing_resume(uuid, bigint[]) from public, anon, authenticated;

-- 0127's stale check: extras in place of plants.
create or replace function private.billing_charge_stale(c private.billing_charges, b private.billing)
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
  if c.kind = 'start' and coalesce(b.plan, 'free') <> 'free' then return 'not on Free'; end if;
  if c.kind = 'upgrade' and (coalesce(b.plan, 'free') = 'free' or b.state = 'past_due' or b.period is distinct from c.period) then
    return 'plan changed';
  end if;
  if c.billing_date is distinct from b.next_billing_date then return 'billing date passed'; end if;
  if c.added > 0 and b.next_plan is not null and c.plan = b.plan then return 'plan change booked'; end if;
  if c.extra_plants is distinct from
     (case when c.plan = 'family' then case when b.plan = 'family' then b.extra_plants else 0 end + c.added else 0 end) then
    return 'extra plants changed';
  end if;
  begin
    q := public.billing_upgrade_quote(c.user_id, c.plan, c.added, case when c.kind = 'start' then c.period end, c.created_on);
  exception when sqlstate '22023' then
    return 'not an upgrade';
  end;
  if greatest((q->>'dueNow')::int, 0) <> c.amount then return 'price changed'; end if;
  return null;
end $$;
revoke all on function private.billing_charge_stale(private.billing_charges, private.billing) from public, anon, authenticated;

-- 0128's paid: a start or upgrade sets the extras it paid for, then stopped plants
-- start into the room, oldest first. All or nothing, as in 0128: when a stopped plant
-- that fits the paid room still does not collect, the block rolls back and the charge
-- is marked 'refund:'. Room with no stopped plant to fill counts as delivered: the
-- user links plants into it later.
create or replace function public.billing_charge_paid(p_reference text, p_card jsonb default null,
  p_quiet boolean default false, p_cents bigint default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  today date := private.billing_today();
  v_from text;
  stale text;
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then raise exception 'unknown reference' using errcode = 'P0002'; end if;
  if c.kind = 'card' then
    if c.status <> 'paid' then
      if p_cents is not null and p_cents <> c.amount * 100 then
        raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
      end if;
      update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;
      if p_card is not null and coalesce((p_card->>'reusable')::boolean, false) then
        update private.billing set card = p_card, card_email = (select email from auth.users where id = c.user_id),
               updated_at = now()
         where user_id = c.user_id;
      else
        update private.billing_charges set error = 'card not reusable: not saved' where reference = p_reference;
      end if;
    end if;
    return jsonb_build_object('status', 'paid', 'kind', 'card', 'refund', c.refunded_at is null,
      'saved', p_card is not null and coalesce((p_card->>'reusable')::boolean, false));
  end if;
  if c.status = 'paid' then return jsonb_build_object('status', 'paid', 'again', true, 'kind', c.kind); end if;
  if p_cents is not null and p_cents <> c.amount * 100 then
    raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
  end if;
  select * into b from private.billing where user_id = c.user_id for update;
  perform private.billing_lock(c.user_id);
  v_from := coalesce(b.plan, 'free');
  -- Paid, but the account has moved on since the charge was opened. Paystack has the
  -- money; nothing is applied. The error marks it for a refund from Paystack's dashboard.
  stale := private.billing_charge_stale(c, b);
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
      elsif c.kind = 'upgrade' then
        -- A new plan replaces a booked change; more extras on the same plan keep it, and
        -- replace a booked lowering.
        update private.billing
           set next_plan = case when plan = c.plan then next_plan end, plan = c.plan,
               extra_plants = c.extra_plants, next_extra_plants = null, updated_at = now()
         where user_id = c.user_id;
      else  -- renewal, settle
        update private.billing set state = 'active', past_due_since = null, updated_at = now() where user_id = c.user_id;
      end if;
      if c.kind in ('start', 'upgrade') then
        perform private.billing_resume(c.user_id, null);
        -- Room left and a plant still stopped: the resume was refused part way.
        select * into b from private.billing where user_id = c.user_id;
        if exists (select 1 from public.plant_users where user_id = c.user_id and paused)
           and (select count(*) from public.plant_users where user_id = c.user_id and not paused)
               < least(public.billing_room(b.plan, b.extra_plants), coalesce(private.billing_next_room(b), 2147483647)) then
          raise exception 'paid plants did not start' using errcode = 'BL001';
        end if;
      end if;
      if p_card is not null and coalesce((p_card->>'reusable')::boolean, false) then
        update private.billing set card = p_card, card_email = (select email from auth.users where id = c.user_id)
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
    return jsonb_build_object('status', 'paid', 'applied', false, 'kind', c.kind);
  end if;

  if not p_quiet then
    select * into b from private.billing where user_id = c.user_id;
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (c.user_id,
            case when c.kind in ('start', 'upgrade') then 'bill_upgraded' else 'bill_paid' end,
            'bill:' || p_reference,
            jsonb_build_object('from', v_from, 'to', b.plan, 'plan', b.plan, 'period', b.period,
              'amount', c.amount, 'date', today, 'reference', p_reference,
              'card', private.billing_card_label(coalesce(p_card, b.card)),
              'added', c.added, 'daysLeft', b.next_billing_date - today,
              'extra', b.extra_plants,
              'extraEach', public.billing_amount('family', b.period, 1) - public.billing_amount('family', b.period, 0),
              'nextAmount', public.billing_amount_due(c.user_id), 'nextDate', b.next_billing_date),
            1)
    on conflict do nothing;
  end if;
  return jsonb_build_object('status', 'paid', 'plan', b.plan, 'kind', c.kind);
end $$;

-- The per-inverter counts are gone with the price they made.
drop function if exists private.billing_named_added(uuid, text, bigint[]);
drop function if exists public.billing_extra_inverters(uuid, bigint[]);

do $$
declare f text;
begin
  foreach f in array array['billing_may_link(uuid, text, int[])', 'billing_book_change(uuid, text, text)',
                           'billing_renew(uuid)', 'billing_amount_due(uuid)',
                           'billing_upgrade_quote(uuid, text, int, text, date)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['api_billing_keep(bigint)', 'api_billing_extras(int)', 'api_billing_status()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
revoke all on function private.plant_users_plan_limit() from public, anon, authenticated;
revoke all on function private.billing_fit(uuid, bigint[]) from public, anon, authenticated;
revoke all on function private.billing_to_free(uuid, date) from public, anon, authenticated;
