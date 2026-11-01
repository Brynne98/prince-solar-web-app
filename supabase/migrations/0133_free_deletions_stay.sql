-- ============================================================================
-- 0133 — paying again after a move to Free does not cancel its deletions (Brynne,
-- 2026-11-01, option 2; replaces 0132's T2 rule).
--
-- The move to Free books the plants it stops for deletion in 30 days. A later paid start
-- keeps only the plants the new plan starts (billing_resume takes them off the list);
-- the rest are still deleted on that date. A plant the user swaps in on the paid plan
-- (stop one, start this one) collects, so it is kept too. Keep does not save one: on
-- any plan it is refused for a plant the move to Free booked (only a start does), as on
-- Free since 0131. Removals booked by Remove login on a paid plan are unchanged: Keep
-- undoes them, a start does not (F11).
-- private.billing.free_removals marks the plants the move to Free booked; it counts only
-- with plants_to_remove. api_link_status says so per plant (freeRemoval), so Billing
-- shows the delete date with the plant's switch, not Keep.
-- ============================================================================

alter table private.billing add column if not exists free_removals bigint[] not null default '{}';

-- 0131's move to Free, marking what it books.
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


-- 0132's paid, without 0132's cancel: only the plants the plan starts leave the list (0133).
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


-- 0132's resume, clearing the mark too.
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
  for r in select pu.plant_id from public.plant_users pu
            where pu.user_id = p_user and pu.paused and (p_plants is null or pu.plant_id = any (p_plants))
            order by pu.linked_at, pu.plant_id loop
    perform pg_advisory_xact_lock(r.plant_id);
    others := exists (select 1 from public.plant_users where plant_id = r.plant_id and not paused);
    begin
      update public.plant_users set paused = false where user_id = p_user and plant_id = r.plant_id;
    exception when sqlstate '22023' then
      exit;  -- the room is full
    end;
    if not others then perform private.plant_start_fill(r.plant_id); end if;
    update private.billing
       set plants_to_remove = array_remove(plants_to_remove, r.plant_id), free_removals = array_remove(free_removals, r.plant_id),
           remove_on = case when array_remove(plants_to_remove, r.plant_id) = '{}' then null else remove_on end
     where user_id = p_user and r.plant_id = any (plants_to_remove);
  end loop;
end $$;
revoke all on function private.billing_resume(uuid, bigint[]) from public, anon, authenticated;


-- 0130's start; a swap keeps a plant the move to Free booked on any plan (0133).
create or replace function public.api_plant_start(p_plant bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  others boolean;
  started boolean;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(auth.uid());
  if not exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = p_plant) then
    raise exception 'plant % is not linked to this user', p_plant using errcode = '42501';
  end if;
  -- The plant's lock before its row, as billing_drop_plant and plant_start_fill take it.
  perform pg_advisory_xact_lock(p_plant);
  others := exists (select 1 from public.plant_users where plant_id = p_plant and not paused);
  update public.plant_users set paused = false where user_id = auth.uid() and plant_id = p_plant and paused;
  started := found;
  if started and not others then perform private.plant_start_fill(p_plant); end if;
  if not started then return jsonb_build_object('started', true); end if;
  -- Swapped in on Free, or on any plan for a plant the move to Free booked (0133): it collects, so it stays.
  update private.billing
     set plants_to_remove = array_remove(plants_to_remove, p_plant),
         remove_on = case when array_remove(plants_to_remove, p_plant) = '{}' then null else remove_on end,
         free_removals = array_remove(free_removals, p_plant),
         updated_at = now()
   where user_id = auth.uid() and p_plant = any (plants_to_remove) and (plan = 'free' or p_plant = any (free_removals));
  return jsonb_build_object('started', true);
end $$;


-- 0131's keep, refused for a plant the move to Free booked on any plan (0133).
create or replace function public.api_billing_keep(p_plant bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(auth.uid());
  select * into b from private.billing where user_id = auth.uid() for update;
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


-- 0132's run; the mark goes with the removals.
create or replace function public.billing_run(p_today date default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  today date := coalesce(p_today, private.billing_today());
  b private.billing;
  r jsonb;
  c private.billing_charges;
  ref text;
  out jsonb := '[]'::jsonb;
  p bigint;
  s int;
begin
  perform pg_advisory_xact_lock(hashtext('billing_run'));

  -- Lost disputes owed, on a quiet day (0132). First, before this call holds any user
  -- lock: they lock charge rows before the user, as a dispute event does.
  for b in select bl.* from private.billing bl
            where exists (select 1 from private.billing_charges x where x.user_id = bl.user_id and x.dispute_owed)
            order by bl.user_id loop
    perform private.billing_dispute_apply(b.user_id, today);
  end loop;

  -- A renewal handed out and not reported: handed out again with its reference.
  for c in select * from private.billing_charges
            where kind = 'renewal' and status = 'pending'
              and (claimed_at is null or claimed_at < now() - interval '10 minutes' or created_on < today)
            order by created_at, reference loop
    select * into b from private.billing where user_id = c.user_id;
    if private.billing_charge_stale(c, b) is not null then
      update private.billing_charges set status = 'failed', error = 'not charged: no longer due', settled_at = now()
       where reference = c.reference;
      continue;
    end if;
    -- Expired before its day is counted (0132), so today still gets its retry.
    if c.tried_on <= today - 3 then
      perform public.billing_charge_failed(c.reference, 'not settled at Paystack 3 days after the first try');
      continue;
    end if;
    -- handed_from: the day it was last handed out, given back if this call never starts it (0132)
    update private.billing_charges set handed_from = case when created_on < today then created_on else handed_from end,
           created_on = greatest(created_on, today) where reference = c.reference;
    out := out || jsonb_build_object('reference', c.reference, 'amount', c.amount, 'card', b.card->>'authorization_code',
                                     'email', coalesce(b.card_email, (select email from auth.users where id = c.user_id)));
  end loop;

  -- Free from day 8, once all four tries are made and none is open.
  for b in select * from private.billing bl
            where state = 'past_due' and today - past_due_since >= 8
              and not exists (select 1 from private.billing_charges x
                               where x.user_id = bl.user_id and x.kind = 'renewal' and x.status = 'pending') loop
    if private.billing_try_slot(b.user_id, b.past_due_since) is null then
      perform private.billing_to_free(b.user_id, today);
    end if;
  end loop;

  -- Retries: the next of day 1, 3 and 7 once its day has come; one a day, none while one is open.
  for b in select * from private.billing bl
            where state = 'past_due'
              and not exists (select 1 from private.billing_charges x
                               where x.user_id = bl.user_id and x.kind = 'renewal'
                                 and (x.created_on = today or x.status = 'pending')) loop
    s := private.billing_try_slot(b.user_id, b.past_due_since);
    continue when s is null or today - b.past_due_since < s;
    select * into c from private.billing_charges
     where user_id = b.user_id and kind = 'renewal' and due_on = b.past_due_since order by created_at limit 1;
    ref := 'psh_' || replace(gen_random_uuid()::text, '-', '');
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on)
    values (ref, b.user_id, 'renewal', c.plan, c.period, c.amount, c.due_on, today);
    out := out || jsonb_build_object('reference', ref, 'amount', c.amount, 'card', b.card->>'authorization_code',
                                     'email', coalesce(b.card_email, (select email from auth.users where id = b.user_id)));
  end loop;

  -- Billing dates.
  for b in select * from private.billing
            where plan <> 'free' and not comped and state = 'active' and next_billing_date <= today loop
    r := public.billing_renew(b.user_id);
    if (r->>'plan') <> 'free' and (r->>'charge')::int > 0 then
      ref := 'psh_' || replace(gen_random_uuid()::text, '-', '');
      insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on)
      select ref, b.user_id, 'renewal', bl.plan, bl.period, (r->>'charge')::int, b.next_billing_date, today
        from private.billing bl where bl.user_id = b.user_id;
      out := out || jsonb_build_object('reference', ref, 'amount', (r->>'charge')::int, 'card', b.card->>'authorization_code',
                                       'email', coalesce(b.card_email, (select email from auth.users where id = b.user_id)));
    end if;
  end loop;

  -- No saved card: fails now (the user gets the "pay with another card" email).
  for r in select x from jsonb_array_elements(out) x where x->>'card' is null loop
    perform public.billing_charge_failed(r->>'reference', 'no saved card');
  end loop;
  out := coalesce((select jsonb_agg(x) from jsonb_array_elements(out) x where x->>'card' is not null), '[]'::jsonb);
  update private.billing_charges set claimed_at = now(), tried_on = coalesce(tried_on, today)
   where reference in (select x->>'reference' from jsonb_array_elements(out) x);

  -- Booked removals due today, or missed. The user lock and the list read again (0132):
  -- a plant started meanwhile is off the list, and the lock order is a payment's.
  for b in select * from private.billing where remove_on <= today and cardinality(plants_to_remove) > 0 loop
    perform private.billing_lock(b.user_id);
    select * into b from private.billing where user_id = b.user_id for update;
    continue when b.remove_on is null or b.remove_on > today;
    foreach p in array (select array_agg(x order by x) from unnest(b.plants_to_remove) x) loop
      perform private.billing_drop_plant(b.user_id, p);
    end loop;
    update private.billing set plants_to_remove = '{}', remove_on = null, free_removals = '{}', updated_at = now()
     where user_id = b.user_id;
  end loop;

  -- Card pages left unpaid 2 days: closed (0132). A late payment still applies or is refunded.
  update private.billing_charges set status = 'failed', error = 'card page not finished', settled_at = now()
   where status = 'pending' and kind in ('start', 'upgrade', 'settle', 'card') and created_at < now() - interval '2 days';

  -- Up to 3 days before a removal, once.
  insert into public.email_queue (user_id, kind, key, data, priority)
  select bl.user_id, 'bill_removal_soon', 'bill_removal_soon:' || bl.remove_on,
         jsonb_build_object('on', bl.remove_on,
           'plants', (select jsonb_agg(pu.plant_name order by pu.linked_at) from public.plant_users pu
                       where pu.user_id = bl.user_id and pu.plant_id = any (bl.plants_to_remove))), 1
    from private.billing bl
   where bl.remove_on > today and bl.remove_on <= today + 3 and cardinality(bl.plants_to_remove) > 0
  on conflict do nothing;

  -- Yearly plans, up to 60 days before the date, once.
  insert into public.email_queue (user_id, kind, key, data, priority)
  select bl.user_id, 'bill_renewal_notice', 'bill_renewal_notice:' || bl.next_billing_date,
         jsonb_build_object('plan', coalesce(bl.next_plan, bl.plan), 'on', bl.next_billing_date,
           'amount', public.billing_amount_due(bl.user_id),
           'changed', bl.next_plan is not null or bl.next_period is not null), 1
    from private.billing bl
   where bl.period = 'yearly' and not bl.comped and bl.state = 'active'
     and bl.next_billing_date > today and bl.next_billing_date <= today + 60
     and coalesce(bl.next_plan, bl.plan) <> 'free' and coalesce(bl.next_period, bl.period) = 'yearly'
  on conflict do nothing;

  return out;
end $$;


-- 0112's link status, with free_removal per plant.
CREATE OR REPLACE FUNCTION public.api_link_status()
 RETURNS TABLE(account_id uuid, sunsynk_username text, status text, linked_at timestamp with time zone, last_ok_at timestamp with time zone, plants jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select a.id, a.sunsynk_username, a.status, a.linked_at, a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name,
                                                        'paused', pu.paused,
                                                        'inverters', (select count(*) from private.inverters i where i.plant_id = pu.plant_id),
                                                        'remove_on', case when pu.plant_id = any (b.plants_to_remove) then b.remove_on end,
                                                        -- booked by the move to Free: kept only by starting it (0133)
                                                        'free_removal', pu.plant_id = any (b.plants_to_remove) and pu.plant_id = any (b.free_removals))
                                    order by pu.linked_at, pu.plant_id)
                     from public.plant_users pu
                     left join private.billing b on b.user_id = pu.user_id
                    where pu.account_id = a.id and pu.user_id = auth.uid()),
                  '[]'::jsonb)
    from private.sunsynk_accounts a
   where a.user_id = auth.uid()
   order by a.linked_at desc
$function$;


-- 0130's comped switch, clearing the mark with the list.
create or replace function public.billing_set_comped(p_user uuid, p_comped boolean)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  if not exists (select 1 from auth.users where id = p_user) then
    raise exception 'no such user' using errcode = '22023';
  end if;
  perform private.billing_lock(p_user);
  if p_comped then
    insert into private.billing (user_id, plan, comped) values (p_user, 'family', true)
    on conflict (user_id) do update
      set plan = 'family', comped = true, period = null, billing_day = null, next_billing_date = null,
          next_plan = null, next_period = null, extra_plants = 0, next_extra_plants = null,
          state = 'active', past_due_since = null, plants_to_remove = '{}', free_removals = '{}', remove_on = null, updated_at = now();
  else
    update private.billing
       set plan = 'free', comped = false, period = null, billing_day = null, next_billing_date = null,
           next_plan = null, next_period = null, extra_plants = 0, next_extra_plants = null,
           state = 'active', past_due_since = null, updated_at = now()
     where user_id = p_user and comped;
    perform private.billing_fit(p_user, '{}');
    insert into private.free_week_logins (sunsynk_username, user_id, started_at)
    select coalesce(lower(a.sunsynk_username), ''), pu.user_id, pu.linked_at
      from public.plant_users pu left join private.sunsynk_accounts a on a.id = pu.account_id
     where pu.user_id = p_user
     order by pu.linked_at limit 1
    on conflict do nothing;
  end if;
  return jsonb_build_object('plan', (select plan from private.billing where user_id = p_user),
    'comped', p_comped,
    'collecting', (select count(*) from public.plant_users where user_id = p_user and not paused));
end $$;
