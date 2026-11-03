-- 0145 — Offers (SOLAR-330, decided 2026-11-03).
-- List prices stay Home R99/R999, Family R179/R1,799, extra plant R49/R588. An offer is a
-- set of lower prices with three settings: who can join (from opens_on, until joins_until,
-- while fewer than max_payers have joined), and how long the price lasts (months from
-- joining; null = while the plan stays paid).
-- - An account joins when its first payment from Free is paid, at the offer it was quoted
--   (billing_charges.offer_id), even if the last place went meanwhile.
-- - offer_members keeps every account that ever joined: max_payers counts them all, and a
--   place given up never reopens. An account joins an offer once.
-- - Back to Free (cancel reached its date, failed payments, any route): the offer goes.
--   A cancel undone before the billing date keeps it, since the plan never left.
-- - A price that ends: one email up to 30 days before the first charge at the list price.
-- - Comped accounts never join.
-- Offers are added by a migration (insert into private.offers), no admin page.

create table private.offers (
  id text primary key,
  home_monthly int not null check (home_monthly > 0),
  home_yearly int not null check (home_yearly > 0),
  family_monthly int not null check (family_monthly > 0),
  family_yearly int not null check (family_yearly > 0),
  extra_monthly int not null check (extra_monthly > 0),
  extra_yearly int not null check (extra_yearly > 0),
  opens_on date not null default (now() at time zone 'Africa/Johannesburg')::date,
  joins_until date,
  max_payers int check (max_payers > 0),
  months int check (months > 0),
  created_at timestamptz not null default now()
);

-- No foreign key to auth.users: a deleted account still holds its place.
create table private.offer_members (
  offer_id text not null references private.offers (id),
  user_id uuid not null,
  joined_on date not null,
  primary key (offer_id, user_id)
);

alter table private.billing
  add column offer_id text references private.offers (id),
  add column offer_until date;
alter table private.billing_charges add column offer_id text references private.offers (id);

insert into private.offers (id, home_monthly, home_yearly, family_monthly, family_yearly, extra_monthly, extra_yearly, max_payers)
values ('launch', 49, 490, 89, 890, 29, 290, 100);

-- The offer a Free account would join if it paid on p_day: the newest open one with room.
create or replace function private.billing_offer_open(p_user uuid, p_day date)
returns text language sql stable set search_path = public, private, pg_temp as $$
  select o.id from private.offers o
   where o.opens_on <= p_day and (o.joins_until is null or p_day <= o.joins_until)
     and (o.max_payers is null or (select count(*) from private.offer_members m where m.offer_id = o.id) < o.max_payers)
     and not exists (select 1 from private.offer_members m where m.offer_id = o.id and m.user_id = p_user)
     and not coalesce((select b.comped from private.billing b where b.user_id = p_user), false)
   order by o.opens_on desc, o.created_at desc
   limit 1
$$;

-- The offer an account holds for a charge on p_day: null once its months have run out.
create or replace function private.billing_offer(p_user uuid, p_day date)
returns text language sql stable set search_path = public, private, pg_temp as $$
  select b.offer_id from private.billing b
   where b.user_id = p_user and b.offer_id is not null and not b.comped
     and (b.offer_until is null or p_day < b.offer_until)
$$;

-- What a Free account is quoted and what a paid one holds, today.
create or replace function private.billing_offer_now(p_user uuid)
returns text language sql stable set search_path = public, private, pg_temp as $$
  select case when coalesce((select b.plan from private.billing b where b.user_id = p_user), 'free') = 'free'
              then private.billing_offer_open(p_user, private.billing_today())
              else private.billing_offer(p_user, private.billing_today()) end
$$;

-- For screens: the offer's terms, or null.
create or replace function private.billing_offer_json(p_offer text, p_user uuid default null)
returns jsonb language sql stable set search_path = public, private, pg_temp as $$
  select jsonb_build_object('id', o.id, 'months', o.months, 'cap', o.max_payers, 'joinsUntil', o.joins_until,
           'held', coalesce(b.offer_id = o.id and b.plan <> 'free', false), 'until', case when b.offer_id = o.id then b.offer_until end)
    from private.offers o left join private.billing b on b.user_id = p_user
   where o.id = p_offer
$$;

-- Back to Free: the offer goes, whatever the route.
create or replace function private.billing_offer_drop()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  new.offer_id := null;
  new.offer_until := null;
  return new;
end $$;
create trigger billing_offer_drop before update of plan on private.billing
  for each row when (new.plan = 'free' and old.offer_id is not null) execute function private.billing_offer_drop();

-- p_offer: the offer's prices; null = list prices.
drop function public.billing_amount(text, text, int);
create function public.billing_amount(p_plan text, p_period text, p_extra int default 0, p_offer text default null)
returns int language sql stable security definer set search_path = public, private, pg_temp as $$
  select case p_plan
    when 'free'   then 0
    when 'home'   then case p_period when 'monthly' then coalesce(o.home_monthly, 99) when 'yearly' then coalesce(o.home_yearly, 999) end
    when 'family' then case p_period when 'monthly' then coalesce(o.family_monthly, 179) when 'yearly' then coalesce(o.family_yearly, 1799) end
                       + greatest(p_extra, 0) * case p_period when 'monthly' then coalesce(o.extra_monthly, 49)
                                                              when 'yearly' then coalesce(o.extra_yearly, 588) end
  end
  from (select 1) x left join private.offers o on o.id = p_offer
$$;

create or replace function public.billing_amount_due(p_user uuid)
returns int language sql stable security definer set search_path = public, private, pg_temp as $$
  select coalesce((
    select public.billing_amount(coalesce(b.next_plan, b.plan), coalesce(b.next_period, b.period),
             coalesce(b.next_extra_plants, b.extra_plants), private.billing_offer(p_user, b.next_billing_date))
      from private.billing b
     where b.user_id = p_user and b.plan <> 'free' and not b.comped and coalesce(b.next_plan, b.plan) <> 'free'), 0)
$$;

-- p_offer: the offer a start is priced at ('' = list prices); null = the one open now.
-- Adds listCharge (nextCharge at list prices) and offer (the offer nextCharge uses).
drop function public.billing_upgrade_quote(uuid, text, int, text, date);
create function public.billing_upgrade_quote(p_user uuid, p_plan text, p_added int default 0, p_period text default null,
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

do $$
declare f text;
begin
  foreach f in array array['billing_amount(text, text, int, text)', 'billing_upgrade_quote(uuid, text, int, text, date, text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
revoke all on function private.billing_offer_open(uuid, date) from public, anon, authenticated;
revoke all on function private.billing_offer(uuid, date) from public, anon, authenticated;
revoke all on function private.billing_offer_now(uuid) from public, anon, authenticated;
revoke all on function private.billing_offer_json(text, uuid) from public, anon, authenticated;
revoke all on function private.billing_offer_drop() from public, anon, authenticated;

-- A start records the offer it was quoted.
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

-- A start is checked at the offer it was quoted, so a place filled meanwhile is no price change.
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
                                      coalesce(p_day, private.billing_today()),
                                      case when c.kind = 'start' then coalesce(c.offer_id, '') end);
  exception when sqlstate '22023' then
    return 'not an upgrade';
  end;
  if greatest((q->>'dueNow')::int, 0) <> c.amount then return 'price changed'; end if;
  return null;
end $$;
revoke all on function private.billing_charge_stale(private.billing_charges, private.billing, date) from public, anon, authenticated;

-- A paid start joins the offer it was quoted.
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
        if c.offer_id is not null then
          update private.billing b2
             set offer_id = c.offer_id,
                 offer_until = (select (today + make_interval(months => o.months))::date from private.offers o
                                 where o.id = c.offer_id and o.months is not null)
           where b2.user_id = c.user_id;
          insert into private.offer_members (offer_id, user_id, joined_on) values (c.offer_id, c.user_id, today)
          on conflict do nothing;
        end if;
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

-- extraPrice at the account's offer.
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
         case when coalesce(b.plan, 'free') = 'free' or (p_plan = b.plan and b.period = 'monthly') then p_period end);
  why := case when coalesce(b.comped, false) then 'comped'
              when b.state = 'past_due' then 'past_due'
              when b.prepaid_on is not null then 'year_paid'
              when b.next_plan is not null and p_plan = b.plan and (added > 0 or q ? 'switch') then 'plan_change' end;
  if why is not null then q := q || jsonb_build_object('dueNow', null, 'refused', why); end if;
  return jsonb_build_object('plan', coalesce(b.plan, 'free'), 'period', b.period,
           'offerTerms', private.billing_offer_json(q->>'offer', auth.uid()),
           'extraPlants', coalesce(b.extra_plants, 0),
           'extraPrice', public.billing_amount('family', coalesce(b.period, p_period), 1, v_offer)
                         - public.billing_amount('family', coalesce(b.period, p_period), 0, v_offer),
           'listExtraPrice', public.billing_amount('family', coalesce(b.period, p_period), 1)
                         - public.billing_amount('family', coalesce(b.period, p_period), 0))
      || q;
end $$;

-- prices: at the account's offer (quoted on Free, held on a paid plan); listPrices: list;
-- offer: its terms, or null. price: the plan held, at the offer held today.
create or replace function public.api_billing_status()
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  v_offer text := private.billing_offer_now(auth.uid());
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid();
  return jsonb_build_object(
    'plan', coalesce(b.plan, 'free'), 'period', b.period, 'state', coalesce(b.state, 'active'),
    'comped', coalesce(b.comped, false),
    'nextDate', b.next_billing_date,
    'nextAmount', public.billing_amount_due(auth.uid()),
    'price', public.billing_amount(coalesce(b.plan, 'free'), b.period, coalesce(b.extra_plants, 0), v_offer),
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
    -- added: extra plants this charge bought; extra: extra plants it paid for in all;
    -- prev: the plan of the payment before, so extra plants bought on the same plan
    -- don't read as an upgrade (SOLAR-302).
    'payments', coalesce((select jsonb_agg(p order by p->>'at' desc) from (
                  select jsonb_build_object('at', c.settled_at, 'date', (c.settled_at at time zone 'Africa/Johannesburg')::date,
                           'kind', c.kind, 'plan', c.plan, 'period', c.period, 'amount', c.amount,
                           'added', coalesce(c.added, 0), 'extra', coalesce(c.extra_plants, 0), 'prev', c.prev) p
                    from (select c.*, lag(c.plan) over (order by c.settled_at) as prev
                            from private.billing_charges c
                           where c.user_id = auth.uid() and c.status = 'paid' and c.kind <> 'card' and c.amount > 0
                             and c.error is null and coalesce(c.refund_status, 'failed') = 'failed') c
                   order by c.settled_at desc limit 6) x), '[]'::jsonb),
    'prices', private.billing_price_list(v_offer),
    'listPrices', private.billing_price_list(null),
    'offer', private.billing_offer_json(v_offer, auth.uid()));
end $$;

create or replace function private.billing_price_list(p_offer text)
returns jsonb language sql stable set search_path = public, private, pg_temp as $$
  select jsonb_build_object(
    'monthly', jsonb_build_object('home', public.billing_amount('home', 'monthly', 0, p_offer),
                 'family', public.billing_amount('family', 'monthly', 0, p_offer),
                 'extra', public.billing_amount('family', 'monthly', 1, p_offer) - public.billing_amount('family', 'monthly', 0, p_offer)),
    'yearly', jsonb_build_object('home', public.billing_amount('home', 'yearly', 0, p_offer),
                 'family', public.billing_amount('family', 'yearly', 0, p_offer),
                 'extra', public.billing_amount('family', 'yearly', 1, p_offer) - public.billing_amount('family', 'yearly', 0, p_offer)))
$$;
revoke all on function private.billing_price_list(text) from public, anon, authenticated;

-- The website: the offer a new account would join today, and list prices. No account needed.
create or replace function public.api_offer()
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object('prices', private.billing_price_list(o.id), 'listPrices', private.billing_price_list(null),
           'offer', private.billing_offer_json(o.id))
    from (select private.billing_offer_open(null, private.billing_today()) as id) o
$$;
revoke all on function public.api_offer() from public;
grant execute on function public.api_offer() to anon, authenticated;

-- The free week's last email quotes the price the account would pay.
create or replace function private.free_week_mail()
returns int language plpgsql security definer set search_path = public, private, pg_temp as $$
declare n int;
begin
  with fw as (
    select f.user_id, min(f.started_at) as started
      from private.free_week_logins f
      left join private.billing b on b.user_id = f.user_id
     where coalesce(b.plan, 'free') = 'free'
     group by f.user_id
  ), first_plant as (
    select distinct on (pu.user_id) pu.user_id, pu.plant_id
      from public.plant_users pu where not pu.paused
     order by pu.user_id, pu.linked_at, pu.plant_id
  ), setup as (
    select fw.user_id, fp.plant_id, private.setup_steps_left(fw.user_id, fp.plant_id) as steps
      from fw join first_plant fp on fp.user_id = fw.user_id
     where now() >= fw.started + interval '2 days' and now() < fw.started + interval '3 days'
  )
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
  select s.user_id, s.plant_id, 'free_week_setup', 'free_week_setup:' || s.user_id,
         jsonb_build_object('steps', to_jsonb(s.steps)), 1
    from setup s
   where cardinality(s.steps) > 0
  union all
  select fw.user_id, fp.plant_id, 'free_week_soon', 'free_week_soon:' || fw.user_id,
         jsonb_build_object('endsAt', extract(epoch from fw.started + interval '7 days')::bigint,
           -- days with a total, before today: what the trim takes on the day the week ends
           'days', (select count(*) from public.plant_energy e
                     where e.plant_id = fp.plant_id and e.bucket = 'day'
                       and e.period < public.today_tz(public.plant_tz(fp.plant_id))),
           'perMonth', round(public.billing_amount('home', 'yearly', 0,
                         private.billing_offer_open(fw.user_id, private.billing_today())) / 12.0)::int), 1
    from fw left join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.started + interval '5 days' and now() < fw.started + interval '6 days'
  union all
  select fw.user_id, fp.plant_id, 'report_week', 'report_week:free:' || fw.user_id,
         jsonb_build_object('today', timezone(public.plant_tz(fp.plant_id), now())::date, 'freeWeekEnds', true), 2
    from fw join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.started + interval '7 days' and now() < fw.started + interval '8 days'
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- An offer price that ends: one email once the first charge at the list price is 30 days off or less.
create or replace function private.offer_end_mail(p_today date default null)
returns int language plpgsql security definer set search_path = public, private, pg_temp as $$
declare n int; today date := coalesce(p_today, private.billing_today());
begin
  insert into public.email_queue (user_id, kind, key, data, priority)
  select b.user_id, 'bill_offer_ends', 'bill_offer_ends:' || b.offer_id || ':' || b.user_id,
         jsonb_build_object('plan', coalesce(b.next_plan, b.plan), 'on', b.next_billing_date,
           'amount', public.billing_amount_due(b.user_id),
           'was', public.billing_amount(coalesce(b.next_plan, b.plan), coalesce(b.next_period, b.period),
                    coalesce(b.next_extra_plants, b.extra_plants), b.offer_id),
           'period', coalesce(b.next_period, b.period),
           'card', case when b.card is not null then private.billing_card_label(b.card) end), 1
    from private.billing b
   where b.offer_until is not null and b.plan <> 'free' and not b.comped and b.state = 'active'
     and coalesce(b.next_plan, b.plan) <> 'free'
     and b.next_billing_date >= b.offer_until and b.next_billing_date > today and b.next_billing_date <= today + 30
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function private.offer_end_mail(date) from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping jobs (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'offer-end-mail') then
    perform cron.unschedule('offer-end-mail');
  end if;
  perform cron.schedule('offer-end-mail', '30 6 * * *', 'select private.offer_end_mail()');
end $$;
