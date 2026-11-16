-- ============================================================================
-- 0212 — a failed card ends like a cancel; offers are for new members (SOLAR-564,
--        decided by Brynne 2026-11-16).
--
-- Before: day 8 of a failed card moved the account to the old Free plan
-- (billing_to_free, 0197): one plant stayed open, the others locked and were
-- booked for removal 30 days on, keep_until let the history be read for 30 days,
-- and the reminder emails said the app had stopped while it was still open.
--
-- Now, day 8 of a failed card:
--   - the plan ends as a cancel's does: no plan, every plant stays linked and
--     ticked, nothing is locked or booked for removal;
--   - keep_until stays null, so the pay screen shows at once (api_me's wall) and
--     nothing is read;
--   - ended_at is set, so the unpaid emails go on day 14 and 27 and the history is
--     deleted on day 30 (unpaid_delete, 0209), with its one email;
--   - one bill_free email; the bill_free notice in the app is gone (the pay screen
--     says it).
--
-- Offers:
--   - billing_offer_open: an account that ever paid gets no new offer. An account
--     that joined an offer gets that offer again while it is open, also when its
--     places are all taken.
--   - billing_charge_paid: a member coming back keeps its place in the cap, and a
--     time-limited offer counts its months from the day it first joined; once they
--     have run out it is not quoted again.
--   - unpaid_since and the day-14 and day-27 emails also cover an account with no
--     free-week row: the pay screen, the emails and the delete go by its end date.
-- ============================================================================

-- 0204's trigger: ended_at as before; keep_until no longer set for a failed card.
create or replace function private.billing_keep_until()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  if new.plan <> 'free' then
    new.keep_until := null;
    new.ended_at := null;
  elsif old.plan in ('home', 'family') then
    new.ended_at := now();
    new.keep_until := null;
  end if;
  return new;
end $$;
revoke all on function private.billing_keep_until() from public, anon, authenticated;

-- 0197's move to Free, now day 8 of a failed card only: the plan ends, the plants stay.
create or replace function private.billing_to_free(p_user uuid, p_today date)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  b private.billing;
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  update private.billing
     set plan = 'free', period = null, billing_day = null, next_billing_date = null,
         next_plan = null, next_period = null, extra_plants = 0, next_extra_plants = null, next_keep = '{}',
         state = 'active', past_due_since = null, updated_at = now()
   where user_id = p_user;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (p_user, 'bill_free', 'bill_free:' || p_today,
          jsonb_build_object('from', b.plan, 'deleteOn', p_today + 30,
            'plants', (select count(*) from private.plant_picks k where k.user_id = p_user)),
          1)
  on conflict do nothing;
end $$;
revoke all on function private.billing_to_free(uuid, date) from public, anon, authenticated;

-- 0145's open offer, for new members: an account that paid before gets only the offer it
-- already joined, and its place is counted already.
create or replace function private.billing_offer_open(p_user uuid, p_day date)
returns text language sql stable set search_path = public, private, pg_temp as $$
  select o.id from private.offers o
   where o.opens_on <= p_day and (o.joins_until is null or p_day <= o.joins_until)
     and not coalesce((select b.comped from private.billing b where b.user_id = p_user), false)
     and (exists (select 1 from private.offer_members m where m.offer_id = o.id and m.user_id = p_user
                   and (o.months is null or p_day < m.joined_on + make_interval(months => o.months)))
          or (not private.had_plan(p_user)
              and (o.max_payers is null or (select count(*) from private.offer_members m where m.offer_id = o.id) < o.max_payers)))
   order by o.opens_on desc, o.created_at desc
   limit 1
$$;

-- 0204's unpaid_since, also for an account with no free-week row (a login of more than 5
-- plants, 0203): the end of its paid time.
create or replace function private.unpaid_since(p_user uuid)
returns timestamptz
language sql stable set search_path = public, private, pg_temp
as $$
  select case when coalesce(b.plan, 'free') = 'free'
              then greatest((select min(f.started_at) + interval '7 days' from private.free_week_logins f where f.user_id = p_user),
                            b.ended_at) end
    from (select p_user as u) x
    left join private.billing b on b.user_id = x.u
$$;
revoke all on function private.unpaid_since(uuid) from public, anon, authenticated;

-- 0197's billing_charge_paid. Changed: a member coming back joins its offer again.
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
        -- a member coming back holds its place, and its months count from the day it first joined (SOLAR-564)
        if c.offer_id is not null and exists (select 1 from private.offers o where o.id = c.offer_id
             and (o.max_payers is null or (select count(*) from private.offer_members m where m.offer_id = o.id) < o.max_payers
                  or exists (select 1 from private.offer_members m where m.offer_id = o.id and m.user_id = c.user_id))) then
          update private.billing b2
             set offer_id = c.offer_id,
                 offer_until = (select (coalesce((select m.joined_on from private.offer_members m
                                                   where m.offer_id = o.id and m.user_id = c.user_id), today)
                                        + make_interval(months => o.months))::date
                                  from private.offers o where o.id = c.offer_id and o.months is not null)
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

-- 0205's billing_notices, without bill_free: the pay screen says it.
-- ---------------------------------------------------------------------------
create or replace function private.billing_notices()
returns jsonb language plpgsql stable set search_path = public, private, pg_temp as $$
declare
  me uuid := auth.uid();
  b private.billing;
  today date := private.billing_today();
  st jsonb;
  started timestamptz;
  first_plant bigint;
  out jsonb := '[]';
  booked boolean;
begin
  select * into b from private.billing where user_id = me;
  booked := b.next_plan is not null or b.next_period is not null or b.next_extra_plants is not null;

  if b.state = 'past_due' and b.plan <> 'free' then
    -- the same next try and Free date as Billing shows
    st := public.api_billing_status();
    out := out || jsonb_build_object('kind', 'bill_failed', 'plan', b.plan, 'amount', st->'nextAmount',
                                     'nextTry', st->'nextTry', 'freeOn', st->'freeOn');
  end if;

  if b.remove_on > today and b.remove_on <= today + 3 and cardinality(b.plants_to_remove) > 0 then
    -- room: the plants the plan covers from that date (a booked change, else today's plan)
    out := out || jsonb_build_object('kind', 'bill_removal_soon', 'on', b.remove_on,
      'room', coalesce(private.billing_next_room(b), public.billing_room(b.plan, b.extra_plants)),
      'plants', coalesce((select jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at)
                   from plant_users pu where pu.user_id = me and pu.plant_id = any (b.plants_to_remove)), '[]'));
  end if;

  -- a paid switch to yearly (prepaid_on, 0138) has nothing to undo; a cancel in it does (SOLAR-467)
  if b.plan <> 'free' and not b.comped and b.state = 'active' and booked
     and (b.prepaid_on is null or b.next_plan = 'free') then
    out := out || jsonb_build_object('kind', 'bill_change',
      'on', case when b.prepaid_on is not null then public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1)
                 else b.next_billing_date end,
      'plan', b.plan, 'period', b.period, 'nextPlan', b.next_plan, 'nextPeriod', b.next_period,
      'extraPlants', coalesce(b.extra_plants, 0), 'nextExtraPlants', b.next_extra_plants);
  end if;

  if b.period = 'yearly' and not b.comped and b.state = 'active' and not booked
     and b.next_billing_date > today and b.next_billing_date <= today + 60 then
    out := out || jsonb_build_object('kind', 'bill_renewal_notice', 'plan', b.plan, 'on', b.next_billing_date,
                                     'amount', public.billing_amount_due(me));
  end if;

  -- the free week: never paid, as free_week_mail (0145) reads it
  if coalesce(b.plan, 'free') = 'free' and not coalesce(b.comped, false) and b.keep_until is null then
    select min(f.started_at) into started from private.free_week_logins f where f.user_id = me;
    if now() >= started + interval '5 days' and now() < started + interval '7 days' then
      select pu.plant_id into first_plant from plant_users pu where pu.user_id = me and not pu.paused
       order by pu.linked_at, pu.plant_id limit 1;
      out := out || jsonb_build_object('kind', 'free_week_soon',
        'endsAt', started + interval '7 days',
        'plant', (select coalesce(pu.plant_name, 'Plant ' || pu.plant_id) from plant_users pu
                   where pu.user_id = me and pu.plant_id = first_plant),
        'days', (select count(*) from plant_energy e
                  where e.plant_id = first_plant and e.bucket = 'day'
                    and e.period < public.today_tz(public.plant_tz(first_plant))),
        'perMonth', (private.billing_price_list(private.billing_offer_now(me)) #>> '{monthly,home}')::int,
        'list', (private.billing_price_list(null) #>> '{monthly,home}')::int);
    end if;
  end if;

  return out;
end $$;
revoke all on function private.billing_notices() from public, anon, authenticated;

-- 0209's free_week_mail. Changed: the day-14 and day-27 emails also go to an account with
-- no free-week row whose paid time ended.
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
    select distinct on (pu.user_id) pu.user_id, pu.plant_id, pu.linked_at
      from public.plant_users pu where not pu.paused
     order by pu.user_id, pu.linked_at, pu.plant_id
  ), setup as (
    -- Day 2 after the account's first plant, on any plan; Hide on the app's card doesn't stop it.
    select fp.user_id, fp.plant_id, private.setup_steps_open(fp.plant_id) as steps,
           c.has_battery is distinct from false as battery
      from first_plant fp left join public.plant_config c on c.plant_id = fp.plant_id
     where now() >= fp.linked_at + interval '2 days' and now() < fp.linked_at + interval '3 days'
  ), unpaid as (
    select f.user_id, private.unpaid_since(f.user_id) as since
      from (select user_id from private.free_week_logins
             union select user_id from private.billing where ended_at is not null) f
     where exists (select 1 from public.plant_users pu where pu.user_id = f.user_id and not pu.paused)
       and not private.no_week(f.user_id)
  )
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
  select s.user_id, s.plant_id, 'free_week_setup', 'free_week_setup:' || s.user_id,
         jsonb_build_object('steps', to_jsonb(s.steps), 'battery', s.battery), 1
    from setup s
   where cardinality(s.steps) > 0
  union all
  select fw.user_id, fp.plant_id, 'free_week_soon', 'free_week_soon:' || fw.user_id,
         jsonb_build_object('endsAt', extract(epoch from fw.started + interval '7 days')::bigint,
           'plants', (select count(*) from private.plant_picks p where p.user_id = fw.user_id),
           'perMonth', round(public.billing_amount('home', 'yearly', 0,
                         private.billing_offer_open(fw.user_id, private.billing_today())) / 12.0)::int), 1
    from fw left join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.started + interval '5 days' and now() < fw.started + interval '6 days'
  union all
  select fw.user_id, fp.plant_id, 'report_week', 'report_week:free:' || fw.user_id,
         jsonb_build_object('today', timezone(public.plant_tz(fp.plant_id), now())::date, 'freeWeekEnds', true,
           'plants', (select count(*) from private.plant_picks p where p.user_id = fw.user_id),
           'from', timezone(public.plant_tz(fp.plant_id), fw.started)::date), 2
    from fw join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.started + interval '7 days' and now() < fw.started + interval '8 days'
  union all
  select u.user_id, null, k.kind, k.kind || ':' || u.user_id || ':' || u.since::date,
         jsonb_build_object('since', extract(epoch from u.since)::bigint,
           'deleteAt', extract(epoch from u.since + interval '30 days')::bigint,
           'plants', (select count(*) from private.plant_picks p where p.user_id = u.user_id),
           'paid', private.had_plan(u.user_id)), 1
    from unpaid u
   cross join (values ('unpaid_reminder', 14), ('unpaid_last', 27)) k(kind, day)
   where now() >= u.since + make_interval(days => k.day) and now() < u.since + make_interval(days => k.day + 1)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function private.free_week_mail() from public, anon, authenticated;

notify pgrst, 'reload schema';
