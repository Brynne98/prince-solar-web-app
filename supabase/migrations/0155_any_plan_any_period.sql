-- ============================================================================
-- 0155 — Any plan in either period (SOLAR-364).
--
-- Home monthly to Family yearly is paid now: the year starts today at today's price,
-- the unused days of the month come off, and the billing date moves to today. Only
-- monthly to yearly: a yearly plan's unused days can be more than a month costs, and
-- there is no credit to hold the rest.
--
-- A booked plan change takes a booked extras drop with it, and Keep undoes both: one
-- change, as Billing shows it.
--
-- Smaller plans in the other period need nothing here: billing_book_change already
-- saves next_plan with next_period (0138).
-- ============================================================================

-- 0145's quote, with Home monthly to Family yearly.
create or replace function public.billing_upgrade_quote(p_user uuid, p_plan text, p_added int default 0, p_period text default null,
  p_today date default (now() at time zone 'Africa/Johannesburg')::date, p_offer text default null)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  extra int;
  v_add int := case when p_plan = 'family' then greatest(coalesce(p_added, 0), 0) else 0 end;
  old_amt int; new_amt int; nxt date; v_offer text; now_offer text;
begin
  select * into b from private.billing where user_id = p_user;
  if b.plan is null or b.plan = 'free' then
    if p_plan = 'free' or p_period is null then
      raise exception 'upgrade from Free needs a paid plan and a period' using errcode = '22023';
    end if;
    v_offer := case when p_offer is null then private.billing_offer_open(p_user, p_today) else nullif(p_offer, '') end;
    new_amt := public.billing_amount(p_plan, p_period, v_add, v_offer);
    nxt := public.billing_step(p_today, p_period, extract(day from p_today)::int, 1);
    return jsonb_build_object('dueNow', new_amt, 'nextCharge', new_amt, 'nextDate', nxt, 'offer', v_offer,
      'listCharge', public.billing_amount(p_plan, p_period, v_add));
  end if;
  -- The switch: the year from the billing date, at the extras held then, paid now (0138).
  if p_plan = b.plan and b.period = 'monthly' and p_period = 'yearly' then
    extra := case when b.plan = 'family' then coalesce(b.next_extra_plants, b.extra_plants) else 0 end;
    v_offer := private.billing_offer(p_user, b.next_billing_date);
    new_amt := public.billing_amount(b.plan, 'yearly', extra, v_offer);
    return jsonb_build_object('dueNow', new_amt, 'nextCharge', new_amt, 'switch', true, 'startsOn', b.next_billing_date,
      'nextDate', public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1), 'offer', v_offer,
      'listCharge', public.billing_amount(b.plan, 'yearly', extra));
  end if;
  -- Home monthly to Family yearly (SOLAR-364): the year starts today, at today's price; the
  -- unused days of the month paid come off (credit). The billing date moves to today.
  if p_plan = 'family' and b.plan = 'home' and b.period = 'monthly' and p_period = 'yearly' then
    now_offer := private.billing_offer(p_user, p_today);
    nxt := public.billing_step(p_today, 'yearly', extract(day from p_today)::int, 1);
    v_offer := private.billing_offer(p_user, nxt);
    old_amt := public.billing_prorate(public.billing_amount(b.plan, b.period, 0, now_offer), p_today,
                 public.billing_step(b.next_billing_date, b.period, b.billing_day, -1), b.next_billing_date);
    new_amt := public.billing_amount(p_plan, 'yearly', v_add, now_offer);
    return jsonb_build_object('dueNow', new_amt - old_amt, 'credit', old_amt, 'period', 'yearly',
      'nextCharge', public.billing_amount(p_plan, 'yearly', v_add, v_offer), 'nextDate', nxt, 'offer', v_offer,
      'listCharge', public.billing_amount(p_plan, 'yearly', v_add));
  end if;
  if (p_plan = 'home' and b.plan = 'family') or p_plan = 'free' then
    raise exception 'not an upgrade' using errcode = '22023';
  end if;
  extra := case when b.plan = 'family' then b.extra_plants else 0 end;
  -- the days left at today's price, the next charge at the price held on its date
  now_offer := private.billing_offer(p_user, p_today);
  v_offer := private.billing_offer(p_user, b.next_billing_date);
  old_amt := public.billing_amount(b.plan, b.period, extra, now_offer);
  new_amt := public.billing_amount(p_plan, b.period, extra + v_add, now_offer);
  return jsonb_build_object(
    'dueNow', public.billing_prorate(new_amt - old_amt, p_today,
                public.billing_step(b.next_billing_date, b.period, b.billing_day, -1),
                b.next_billing_date),
    'nextCharge', public.billing_amount(p_plan, b.period, extra + v_add, v_offer),
    'nextDate', b.next_billing_date, 'offer', v_offer,
    'listCharge', public.billing_amount(p_plan, b.period, extra + v_add));
end $$;

-- 0145's quote for the app: a monthly plan passes the period.
create or replace function public.api_billing_quote(p_plan text, p_period text default 'monthly', p_extra int default null)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  added int;
  q jsonb;
  why text;
  v_offer text := private.billing_offer_now(auth.uid());
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid();
  added := private.billing_extra_added(b, p_plan, coalesce(p_extra, b.extra_plants));
  q := public.billing_upgrade_quote(auth.uid(), p_plan, added,
         -- a monthly plan passes the period: a switch (0138) or a bigger plan yearly (SOLAR-364)
         case when coalesce(b.plan, 'free') = 'free' or b.period = 'monthly' then p_period end);
  why := case when coalesce(b.comped, false) then 'comped'
              when b.state = 'past_due' then 'past_due'
              when b.prepaid_on is not null then 'year_paid'
              when b.next_plan is not null and p_plan = b.plan and (added > 0 or q ? 'switch') then 'plan_change' end;
  if why is not null then q := q || jsonb_build_object('dueNow', null, 'refused', why); end if;
  return jsonb_build_object('plan', coalesce(b.plan, 'free'), 'period', b.period,
           'offerTerms', private.billing_offer_json(q->>'offer', auth.uid()),
           'extraPlants', coalesce(b.extra_plants, 0),
           'extraPrice', public.billing_amount('family', coalesce(q->>'period', b.period, p_period), 1, v_offer)
                         - public.billing_amount('family', coalesce(q->>'period', b.period, p_period), 0, v_offer),
           'listExtraPrice', public.billing_amount('family', coalesce(q->>'period', b.period, p_period), 1)
                         - public.billing_amount('family', coalesce(q->>'period', b.period, p_period), 0))
      || q;
end $$;

-- 0145's charge: an upgrade into yearly.
create or replace function public.billing_charge_open(p_user uuid, p_plan text, p_period text default null,
  p_extra int default null, p_plants bigint[] default null)
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
  -- an upgrade keeps the period, except Home monthly to Family yearly (SOLAR-364)
  v_period := case when v_kind = 'upgrade' and b.period = 'monthly' and p_period = 'yearly' and p_plan <> b.plan then 'yearly'
                   when v_kind = 'upgrade' then b.period else coalesce(p_period, 'monthly') end;
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
  q := public.billing_upgrade_quote(p_user, p_plan, added, case when v_kind <> 'upgrade' or v_period <> b.period then v_period end, today);
  insert into private.billing_charges (reference, user_id, kind, plan, period, added, extra_plants, plants, email,
                                       amount, due_on, created_on, billing_date, offer_id)
  values (ref, p_user, v_kind, p_plan, v_period, added,
          case when p_plan <> 'family' then 0
               when v_kind = 'switch' then coalesce(b.next_extra_plants, b.extra_plants)
               when b.plan = 'family' then b.extra_plants + added else added end,
          nullif(named, '{}'), v_email,
          greatest((q->>'dueNow')::int, 0), today, today, b.next_billing_date,
          case when v_kind = 'start' then q->>'offer' end);
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

-- 0145's stale check: an upgrade into yearly is not a changed plan.
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

-- 0145's payment: an upgrade into yearly starts a new year today.
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
         -- a plan change or an undo takes a booked extras drop with it: one change (SOLAR-364)
         next_extra_plants = case when p_plan <> b.plan or coalesce(p_period, b.period) = b.period then null
                                  else next_extra_plants end,
         next_keep   = case when p_plan = b.plan and p_keep is null
                              then case when coalesce(p_period, b.period) = b.period or b.next_extra_plants is null then '{}' else next_keep end
                            else private.billing_keep_list(p_user, p_keep) end,
         updated_at  = now()
   where user_id = p_user;
end $$;
