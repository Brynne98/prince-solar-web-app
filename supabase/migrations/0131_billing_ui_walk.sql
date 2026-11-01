-- ============================================================================
-- 0131 — fixes from the billing UI walk (SOLAR-264, 2026-10-31).
--
-- A Family user with plants stopped on purpose who bought one more extra plant on the
-- plans page (no plant named) had every stopped plant started: billing_resume fills all
-- the room. Now a same-plan room purchase with no plant named starts as many plants as
-- it bought, newest linked first (the plants that linked stopped for lack of room). A
-- plant named (the app's "plan is full" path) starts as before. An upgrade to a bigger
-- plan still fills the room: those plants were stopped by the old plan's limit.
-- A start or upgrade to a bigger plan that names a plant (the "plan is full" path) started
-- only that plant, so Free to Family left the 3rd place empty. It now starts the named
-- plant, then fills the rest of the room, oldest first.
-- billing_charge_paid is 0130's with those two changes.
--
-- Code review, 2026-10-31: a newest pick leaves out plants booked for removal; a refund
-- Paystack reports before the payment now sends the refund email; the move to Free keeps
-- the first plant that is not booked for deletion (it kept a booked one, so on remove_on
-- every plant went); a refund accepted and then failed on its 7th try alerts hello@.
--
-- On Free, Keep on a stopped plant booked for deletion is refused: only a swap
-- (api_plant_start) brings one back, so Free never holds stopped plants for good. A kept
-- plant the move to Free starts again refetches its history.
--
-- api_billing_status also says when a past-due account moves to Free (freeOn), so
-- Billing shows that date instead of "Renews on".
-- ============================================================================

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
revoke all on function public.billing_charge_paid(text, jsonb, boolean, bigint, text, timestamptz) from public, anon, authenticated;
grant execute on function public.billing_charge_paid(text, jsonb, boolean, bigint, text, timestamptz) to service_role;

-- 0130's status, with freeOn.
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
    -- past due: the day the account moves to Free if nothing is paid (day 8, as bill_failed says)
    'freeOn', case when b.state = 'past_due' then (select greatest(b.past_due_since + 8,
                case when t is not null then greatest(b.past_due_since + t, private.billing_today()) + 1 end)
                from private.billing_try_slot(b.user_id, b.past_due_since) t) end,
    'nextAmount', public.billing_amount_due(auth.uid()),
    'price', public.billing_amount(coalesce(b.plan, 'free'), b.period, coalesce(b.extra_plants, 0)),
    'extraPlants', coalesce(b.extra_plants, 0), 'nextExtraPlants', b.next_extra_plants,
    'nextPlan', b.next_plan, 'nextPeriod', b.next_period,
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

-- 0130's move to Free, keeping a plant not booked for deletion.
create or replace function private.billing_to_free(p_user uuid, p_today date)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  keep bigint;
  stop bigint[];
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  -- the first linked plant not booked for deletion; all booked: the first linked (0131)
  select plant_id into keep from public.plant_users where user_id = p_user
   order by plant_id = any (coalesce(b.plants_to_remove, '{}')), linked_at, plant_id limit 1;
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

-- 0130's refund events, with the alert after the last try.
drop function if exists public.billing_charge_refund_event(text, text, text);
create or replace function public.billing_charge_refund_event(p_reference text, p_status text, p_reason text default null,
  p_cents bigint default null, p_refund text default null)
returns boolean language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  got jsonb;
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then return false; end if;
  if p_status = 'failed' then
    -- A refund paid out (or a dispute lost) stays done.
    update private.billing_charges
       set refund_status = case when refunds <> '{}' or refund_status = 'done' then refund_status else 'failed' end,
           refunded_at = case when refunds <> '{}' or refund_status = 'done' then refunded_at end,
           error = case when kind = 'card' or error like 'refund%'
                        then private.billing_refund_note(error, coalesce(nullif(p_reason, ''), 'no reason given')) else error end
     where reference = p_reference;
    raise warning 'billing refund % failed: %', p_reference, p_reason;
    -- Accepted, then failed, on the last try: the run asks no more, so hello@ is told (0131).
    if c.refund_tries >= 7 and c.refunds = '{}' and coalesce(c.refund_status, '') <> 'done' then
      insert into public.email_queue (to_email, kind, key, data, priority)
      values ('hello@princesolarhub.co.za', 'bill_mail_failed', 'bill_refund_stuck:' || p_reference,
              jsonb_build_object('kind', 'refund failed 7 times: refund it by hand', 'key', p_reference,
                'user', c.user_id, 'error', left(coalesce(nullif(p_reason, ''), 'no reason given'), 300)), 1)
      on conflict do nothing;
    end if;
  elsif p_status = 'processed' then
    got := c.refunds || jsonb_build_object(coalesce(p_refund, 'refund'), coalesce(p_cents, c.amount * 100::bigint));
    update private.billing_charges
       set refunds = got, refund_status = 'done', refunded_at = coalesce(refunded_at, now()),
           refunded_cents = (select sum(value::bigint) from jsonb_each_text(got))
     where reference = p_reference;
    perform private.billing_refund_mail(c);
  elsif p_status in ('pending', 'processing') then
    update private.billing_charges set refund_status = 'asked', refunded_at = coalesce(refunded_at, now())
     where reference = p_reference and coalesce(refund_status, 'failed') = 'failed';
    perform private.billing_refund_mail(c);
  end if;
  return true;
end $$;
revoke all on function public.billing_charge_refund_event(text, text, text, bigint, text) from public, anon, authenticated;
grant execute on function public.billing_charge_refund_event(text, text, text, bigint, text) to service_role;

-- 0130's keep, refused on Free.
create or replace function public.api_billing_keep(p_plant bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(auth.uid());
  select * into b from private.billing where user_id = auth.uid() for update;
  -- Free: a stopped plant comes back only by swapping it in (api_plant_start), never by Keep (0131).
  if coalesce(b.plan, 'free') = 'free' then raise exception 'start it instead' using errcode = '22023'; end if;
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
