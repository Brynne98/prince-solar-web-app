-- SOLAR-298: monthly to yearly on the same plan is paid at once (option A, 2026-11-01).
-- The yearly price (with Family's extra plants) is charged now; the month already paid
-- runs out, no credit. The billing date stays: on it the plan turns yearly and the date
-- moves a year with no second charge. Once paid there is no undo, and nothing else about
-- the plan changes until that date.

alter table private.billing_charges drop constraint if exists billing_charges_kind_check;
alter table private.billing_charges add constraint billing_charges_kind_check
  check (kind in ('start', 'upgrade', 'renewal', 'settle', 'card', 'switch'));

-- The billing date a switch has paid for; billing_renew charges nothing on it.
alter table private.billing add column if not exists prepaid_on date;

-- A paid year holds the plan as it is until its billing date. Only the renewal that
-- starts the year (which clears prepaid_on) may change it. A move to Free (a lost
-- dispute left unpaid) or comping ends the paid year instead.
create or replace function private.billing_year_paid_guard()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  if new.plan = 'free' or new.comped then
    new.prepaid_on := null;
  elsif old.prepaid_on is not null and new.prepaid_on is not null
     and (new.plan, new.period, new.extra_plants, new.next_plan, new.next_period, new.next_extra_plants)
         is distinct from (old.plan, old.period, old.extra_plants, old.next_plan, old.next_period, old.next_extra_plants) then
    raise exception 'your year is paid: the plan stays until it starts' using errcode = '22023';
  end if;
  return new;
end $$;
drop trigger if exists billing_year_paid_guard on private.billing;
create trigger billing_year_paid_guard before update on private.billing
  for each row execute function private.billing_year_paid_guard();

-- 0129's quote, with the switch: same plan, monthly to yearly, the yearly price now (0138).
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
  -- The switch: the year from the billing date, at the extras held then, paid now (0138).
  if p_plan = b.plan and b.period = 'monthly' and p_period = 'yearly' then
    new_amt := public.billing_amount(b.plan, 'yearly',
                 case when b.plan = 'family' then coalesce(b.next_extra_plants, b.extra_plants) else 0 end);
    return jsonb_build_object('dueNow', new_amt, 'nextCharge', new_amt, 'switch', true, 'startsOn', b.next_billing_date,
      'nextDate', public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1));
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

-- 0130's quote for the app: the switch asks with its period; a paid year refuses (0138).
create or replace function public.api_billing_quote(p_plan text, p_period text default 'monthly', p_extra int default null)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  added int;
  q jsonb;
  why text;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid();
  added := private.billing_extra_added(b, p_plan, coalesce(p_extra, b.extra_plants));
  q := public.billing_upgrade_quote(auth.uid(), p_plan, added,
         case when coalesce(b.plan, 'free') = 'free' or (p_plan = b.plan and b.period = 'monthly') then p_period end);
  why := case when coalesce(b.comped, false) then 'comped'
              when b.state = 'past_due' then 'past_due'
              when b.prepaid_on is not null then 'year_paid'
              when b.next_plan is not null and p_plan = b.plan and (added > 0 or q ? 'switch') then 'plan_change' end;
  if why is not null then q := q || jsonb_build_object('dueNow', null, 'refused', why); end if;
  return jsonb_build_object('plan', coalesce(b.plan, 'free'), 'period', b.period,
           'extraPlants', coalesce(b.extra_plants, 0),
           'extraPrice', public.billing_amount('family', coalesce(b.period, p_period), 1)
                         - public.billing_amount('family', coalesce(b.period, p_period), 0))
      || q;
end $$;

-- 0130's stale check, with the switch (0138).
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
    q := public.billing_upgrade_quote(c.user_id, c.plan, c.added, case when c.kind = 'start' then c.period end,
                                      coalesce(p_day, private.billing_today()));
  exception when sqlstate '22023' then
    return 'not an upgrade';
  end;
  if greatest((q->>'dueNow')::int, 0) <> c.amount then return 'price changed'; end if;
  return null;
end $$;

-- 0130's open, with the switch (0138).
create or replace function public.billing_charge_open(
  p_user uuid, p_plan text, p_period text default null, p_extra int default null, p_plants bigint[] default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  q jsonb;
  ref text := 'psh_' || replace(gen_random_uuid()::text, '-', '');
  v_kind text;
  v_period text;
  added int;
  named bigint[];
  v_email text := (select email from auth.users where id = p_user);
  today date := private.billing_today();
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  if b.comped then raise exception 'this plan is free of charge' using errcode = '22023'; end if;
  if b.state = 'past_due' then raise exception 'settle the failed payment first' using errcode = '22023'; end if;
  if b.prepaid_on is not null then
    raise exception 'your year is paid: the plan stays until it starts' using errcode = '22023';
  end if;
  v_kind := case when coalesce(b.plan, 'free') = 'free' then 'start'
                 when p_plan = b.plan and b.period = 'monthly' and p_period = 'yearly' then 'switch'
                 else 'upgrade' end;
  v_period := case when v_kind = 'upgrade' then b.period else coalesce(p_period, 'monthly') end;
  if v_period not in ('monthly', 'yearly') or p_plan not in ('home', 'family') then
    raise exception 'unknown plan or period' using errcode = '22023';
  end if;
  if p_extra < 0 then raise exception 'unknown plan or period' using errcode = '22023'; end if;
  -- the switch buys a year of what is held from the billing date, no more
  added := case when v_kind = 'switch' then 0 else private.billing_extra_added(b, p_plan, coalesce(p_extra, b.extra_plants)) end;
  if v_kind = 'switch' and b.next_plan is not null then raise exception 'plan change' using errcode = '22023'; end if;
  if v_kind = 'upgrade' and p_plan = b.plan then
    if added = 0 then raise exception 'nothing to buy' using errcode = '22023'; end if;
    if b.next_plan is not null then raise exception 'plan change' using errcode = '22023'; end if;
  end if;
  named := array(select pu.plant_id from public.plant_users pu
                  where pu.user_id = p_user and pu.paused and pu.plant_id = any (coalesce(p_plants, '{}'))
                  order by pu.linked_at, pu.plant_id);
  q := public.billing_upgrade_quote(p_user, p_plan, added, case when v_kind <> 'upgrade' then v_period end, today);
  insert into private.billing_charges (reference, user_id, kind, plan, period, added, extra_plants, plants, email,
                                       amount, due_on, created_on, billing_date)
  values (ref, p_user, v_kind, p_plan, v_period, added,
          case when p_plan <> 'family' then 0
               when v_kind = 'switch' then coalesce(b.next_extra_plants, b.extra_plants)
               when b.plan = 'family' then b.extra_plants + added else added end,
          nullif(named, '{}'), v_email,
          greatest((q->>'dueNow')::int, 0), today, today, b.next_billing_date);
  if (q->>'dueNow')::int <= 0 then
    if (public.billing_charge_paid(ref, null, true)->>'applied') = 'false' then
      raise exception 'nothing changed' using errcode = '22023';
    end if;
    return jsonb_build_object('amount', 0, 'reference', ref);
  end if;
  return jsonb_build_object('reference', ref, 'amount', (q->>'dueNow')::int,
    'email', v_email,
    'card', b.card->>'authorization_code',
    -- Paystack charges a saved card only with the email it was saved with.
    'cardEmail', coalesce(b.card_email, v_email));
end $$;

-- 0133's paid, with the switch (0138).
create or replace function public.billing_charge_paid(p_reference text, p_card jsonb default null,
  p_quiet boolean default false, p_cents bigint default null, p_email text default null, p_paid_at timestamptz default null)
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
           and exists (select 1 from public.plant_users where user_id = c.user_id and paused
                        and ((cardinality(named) = 0 and not room_only) or plant_id = any (named))) then
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
              'added', c.added, 'daysLeft', b.next_billing_date - today,
              -- a switch: the extras and price of the year it paid for
              'extra', case when c.kind = 'switch' then c.extra_plants else b.extra_plants end,
              'extraEach', public.billing_amount('family', case when c.kind = 'switch' then 'yearly' else b.period end, 1)
                         - public.billing_amount('family', case when c.kind = 'switch' then 'yearly' else b.period end, 0),
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

-- 0136's renewal: a paid year charges nothing on its date (0138).
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

-- 0136's booking: monthly to yearly is a payment now, not a booking (0138).
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
  if p_plan = b.plan and b.period = 'monthly' and p_period = 'yearly' then
    raise exception 'a switch to yearly is paid now, not booked' using errcode = '22023';
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

-- 0130's status, with prepaidOn (0138).
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
    'nextPlan', b.next_plan, 'nextPeriod', b.next_period, 'prepaidOn', b.prepaid_on,
    'removeOn', b.remove_on,
    'removePlants', coalesce((select jsonb_agg(jsonb_build_object('id', pu.plant_id, 'name', pu.plant_name) order by pu.linked_at)
                                from public.plant_users pu
                               where pu.user_id = auth.uid() and pu.plant_id = any (coalesce(b.plants_to_remove, '{}'))), '[]'::jsonb),
    'card', case when b.card is not null then jsonb_build_object(
              'name', initcap(trim(coalesce(nullif(trim(b.card->>'card_type'), ''), b.card->>'brand', 'card'))),
              'brand', lower(trim(coalesce(nullif(trim(b.card->>'card_type'), ''), b.card->>'brand', 'card'))),
              'last4', b.card->>'last4', 'expMonth', b.card->>'exp_month', 'expYear', b.card->>'exp_year') end,
    'payments', coalesce((select jsonb_agg(p order by p->>'at' desc) from (
                  select jsonb_build_object('at', c.settled_at, 'date', (c.settled_at at time zone 'Africa/Johannesburg')::date,
                           'kind', c.kind, 'plan', c.plan, 'period', c.period, 'amount', c.amount) p
                    from private.billing_charges c
                   where c.user_id = auth.uid() and c.status = 'paid' and c.kind <> 'card' and c.amount > 0
                     and c.error is null and coalesce(c.refund_status, 'failed') = 'failed'
                   order by c.settled_at desc limit 6) x), '[]'::jsonb),
    'prices', jsonb_build_object(
      'monthly', jsonb_build_object('home', public.billing_amount('home', 'monthly'), 'family', public.billing_amount('family', 'monthly'),
                   'extra', public.billing_amount('family', 'monthly', 1) - public.billing_amount('family', 'monthly')),
      'yearly', jsonb_build_object('home', public.billing_amount('home', 'yearly'), 'family', public.billing_amount('family', 'yearly'),
                   'extra', public.billing_amount('family', 'yearly', 1) - public.billing_amount('family', 'yearly'))));
end $$;
