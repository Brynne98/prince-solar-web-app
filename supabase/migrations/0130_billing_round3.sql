-- ============================================================================
-- 0130 — billing break test round 3 (SOLAR-264, decided by Brynne 2026-10-31).
--
-- 1. Account delete is refused while a paid plan runs and is not cancelled, while the
--    account is past due, and while a start, upgrade or settle charge opened in the last
--    day is still open, or a refund has not gone back yet. A booked cancel is enough: the plan runs to its billing date, no
--    refund. A payment for an account deleted anyway (an old card page) is refunded by
--    the webhook (billing/index.ts).
-- 2. card_email is set only when a new card is saved, from the email Paystack reports
--    (else the email the charge was opened with, billing_charges.email). Renewals and
--    upgrades on the saved card never rewrite it.
-- 3. One lock order on every path: the user's charge rows, the user's billing lock, the
--    billing row, the plant's advisory lock, then plant rows. api_plant_start took the plant
--    row first and deadlocked a payment.
-- 4. billing_charge_failed leaves the account alone when the date it is for is already
--    paid (or the account moved on): a retry declined after a settle.
-- 5. Refunds: refund_status asked / done / failed, refunded_cents. A refused refund is
--    tried again by the daily run (billing_refunds_due). A refund Paystack reports
--    before the payment means the payment never applies. A replay of a payment marked
--    for refund answers applied:false again.
-- 6. Retries and notices on or after their day, once each: a missed run day is caught
--    up (billing_try_slot), so there are always 4 tries before Free.
-- 7. A start or upgrade is priced again on the day it is paid; a different price is
--    refunded and the user pays the new one.
-- 8. A lost dispute is an unpaid renewal: past due from that day, retries on day 1, 3
--    and 7, Free on day 8. The dispute is written on the charge.
-- 9. api_plant_start on Free takes the plant off the delete list (the user swapped it in).
-- 10. A paid room purchase starts the plant it was bought for (billing_charges.plants,
--    sent by the app); none named, the oldest stopped.
-- 11. A refund made by hand in Paystack's dashboard is recorded with its amount and
--    leaves Billing's payment list; the plan stays.
-- 12. billing_set_comped: the hand switch for comped, fitting plants to the plan.
-- 14. Refund email to the user (not for the R1 card check); a bill email that fails
--    after its last try alerts hello@.
-- 15. api_billing_quote gives no dueNow where a payment would be refused;
--    billing_set_paused (unused since 0127) is dropped.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Columns
-- ---------------------------------------------------------------------------
-- the email the charge was opened with (the card page uses it)
alter table private.billing_charges add column if not exists email text;
-- asked: Paystack took the refund; done: Paystack paid it out; failed: refused
alter table private.billing_charges add column if not exists refund_status text
  check (refund_status in ('asked', 'done', 'failed'));
alter table private.billing_charges add column if not exists refunded_cents bigint;
-- Paystack's refunds, refund id -> cents, so a replayed event counts once
alter table private.billing_charges add column if not exists refunds jsonb not null default '{}';
alter table private.billing_charges add column if not exists refund_tries int not null default 0;
alter table private.billing_charges add column if not exists refund_tried_at timestamptz;
-- Paystack's dispute status; lost once the money was taken back
alter table private.billing_charges add column if not exists dispute text;
alter table private.billing_charges add column if not exists dispute_lost boolean not null default false;

update private.billing_charges
   set refund_status = case when refunded_at is not null then 'asked' when error like 'refund failed: %' then 'failed' end
 where status = 'paid' and refund_status is null and (refunded_at is not null or error like 'refund failed: %');

-- ---------------------------------------------------------------------------
-- 1. Lock order: user lock, billing row, plant rows
-- ---------------------------------------------------------------------------
-- 0127's start, under the user lock. On Free the plant started is the one the user keeps:
-- off the delete list (a move to Free booked every stopped plant). On a paid plan a plant
-- booked for removal still goes on its date: it collects until then (0127).
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
  update private.billing
     set plants_to_remove = array_remove(plants_to_remove, p_plant),
         remove_on = case when array_remove(plants_to_remove, p_plant) = '{}' then null else remove_on end,
         updated_at = now()
   where user_id = auth.uid() and plan = 'free' and p_plant = any (plants_to_remove);
  return jsonb_build_object('started', true);
end $$;

-- 0129's resume, under the user lock.
create or replace function private.billing_resume(p_user uuid, p_plants bigint[])
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  r record;
  others boolean;
begin
  perform private.billing_lock(p_user);
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
       set plants_to_remove = array_remove(plants_to_remove, r.plant_id),
           remove_on = case when array_remove(plants_to_remove, r.plant_id) = '{}' then null else remove_on end
     where user_id = p_user and r.plant_id = any (plants_to_remove);
  end loop;
end $$;
revoke all on function private.billing_resume(uuid, bigint[]) from public, anon, authenticated;

-- 0129's renewal, the user lock first.
create or replace function public.billing_renew(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  due int;
  v_plan text; v_period text;
  going bigint[];
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

-- 0129's move to Free, the user lock first.
create or replace function private.billing_to_free(p_user uuid, p_today date)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  keep bigint;
  stop bigint[];
begin
  perform private.billing_lock(p_user);
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
revoke all on function private.billing_to_free(uuid, date) from public, anon, authenticated;

-- 0129's booking, keep and extras, the user lock first.
create or replace function public.billing_book_change(p_user uuid, p_plan text, p_period text default null)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  rank constant jsonb := '{"free": 0, "home": 1, "family": 2}';
  keep int;
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

create or replace function public.api_billing_keep(p_plant bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(auth.uid());
  select * into b from private.billing where user_id = auth.uid() for update;
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

create or replace function public.api_billing_extras(p_count int)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  keep int;
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
-- 2. Opening charges: the email sent, the plants bought for
-- ---------------------------------------------------------------------------
-- 0129's open. p_plants: the stopped plants the room is bought for (the app sends them);
-- only this user's stopped plants are kept.
drop function if exists public.billing_charge_open(uuid, text, text, int);
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
  v_kind := case when coalesce(b.plan, 'free') = 'free' then 'start' else 'upgrade' end;
  v_period := case when v_kind = 'start' then coalesce(p_period, 'monthly') else b.period end;
  if v_period not in ('monthly', 'yearly') or p_plan not in ('home', 'family') then
    raise exception 'unknown plan or period' using errcode = '22023';
  end if;
  if p_extra < 0 then raise exception 'unknown plan or period' using errcode = '22023'; end if;
  added := private.billing_extra_added(b, p_plan, coalesce(p_extra, b.extra_plants));
  if v_kind = 'upgrade' and p_plan = b.plan then
    if added = 0 then raise exception 'nothing to buy' using errcode = '22023'; end if;
    if b.next_plan is not null then raise exception 'plan change' using errcode = '22023'; end if;
  end if;
  named := array(select pu.plant_id from public.plant_users pu
                  where pu.user_id = p_user and pu.paused and pu.plant_id = any (coalesce(p_plants, '{}'))
                  order by pu.linked_at, pu.plant_id);
  q := public.billing_upgrade_quote(p_user, p_plan, added, case when v_kind = 'start' then v_period end, today);
  insert into private.billing_charges (reference, user_id, kind, plan, period, added, extra_plants, plants, email,
                                       amount, due_on, created_on, billing_date)
  values (ref, p_user, v_kind, p_plan, v_period, added,
          case when p_plan = 'family' then case when b.plan = 'family' then b.extra_plants else 0 end + added else 0 end,
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
revoke all on function public.billing_charge_open(uuid, text, text, int, bigint[]) from public, anon, authenticated;
grant execute on function public.billing_charge_open(uuid, text, text, int, bigint[]) to service_role;

-- 0116's settle and 0120's card change, with the email sent.
create or replace function public.billing_settle_open(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  c private.billing_charges;
  ref text := 'psh_' || replace(gen_random_uuid()::text, '-', '');
  v_email text := (select email from auth.users where id = p_user);
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  if b.state is distinct from 'past_due' then raise exception 'nothing to pay' using errcode = '22023'; end if;
  select * into c from private.billing_charges
   where user_id = p_user and kind in ('renewal', 'settle') and due_on = b.past_due_since
   order by created_at desc limit 1;
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on, email)
  values (ref, p_user, 'settle', c.plan, c.period, c.amount, c.due_on, private.billing_today(), v_email);
  return jsonb_build_object('reference', ref, 'amount', c.amount, 'email', v_email);
end $$;

create or replace function public.billing_card_open(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  ref text := 'psh_' || replace(gen_random_uuid()::text, '-', '');
  v_email text := (select email from auth.users where id = p_user);
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' or b.comped then
    raise exception 'no card to change' using errcode = '22023';
  end if;
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on, email)
  values (ref, p_user, 'card', b.plan, b.period, 1, private.billing_today(), private.billing_today(), v_email);
  return jsonb_build_object('reference', ref, 'amount', 1, 'email', v_email);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Paid
-- ---------------------------------------------------------------------------
-- 0129's stale check, priced on the day it is paid (p_day, Paystack's paid_at; else
-- today): a card page left open for days pays the share left on that day, or nothing
-- applies and the money goes back.
drop function if exists private.billing_charge_stale(private.billing_charges, private.billing);
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
revoke all on function private.billing_charge_stale(private.billing_charges, private.billing, date) from public, anon, authenticated;

-- 0129's paid. p_email: the email Paystack reports for the customer; p_paid_at: when
-- Paystack took the money (the price is judged on that day). The answer's refund: true
-- when the money should go back now (marked for refund, not yet taken).
drop function if exists public.billing_charge_paid(text, jsonb, boolean, bigint);
drop function if exists public.billing_charge_paid(text, jsonb, boolean, bigint, text);
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
     where reference = p_reference;
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
        perform private.billing_resume(c.user_id, case when cardinality(named) > 0 then named end);
        select * into b from private.billing where user_id = c.user_id;
        room := least(public.billing_room(b.plan, b.extra_plants), coalesce(private.billing_next_room(b), 2147483647));
        -- Room left and a plant to start still stopped: the start was refused part way.
        if (select count(*) from public.plant_users where user_id = c.user_id and not paused) < room
           and exists (select 1 from public.plant_users where user_id = c.user_id and paused
                        and (cardinality(named) = 0 or plant_id = any (named))) then
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

-- ---------------------------------------------------------------------------
-- 4. Failed, and the try days
-- ---------------------------------------------------------------------------
-- Tries for a past-due date fill the slots day 0 (the billing date), 1, 3 and 7. A new
-- charge fills the first open slot after the last filled one, on or before its day; a renewal the run handed out
-- again on a later day is that day's try and fills the last open slot on or before it.
-- Slots left open before the last one filled are passed. Returns the next slot, or null
-- when day 7 is filled.
create or replace function private.billing_try_slot(p_user uuid, p_since date)
returns int language plpgsql stable set search_path = public, private, pg_temp as $$
declare
  slots constant int[] := array[0, 1, 3, 7];
  filled int[] := '{}';
  r record;
  best int;
begin
  for r in select coalesce(tried_on, created_on) - p_since as t,
                  case when created_on > tried_on then created_on - p_since end as again
             from private.billing_charges
            where user_id = p_user and kind = 'renewal' and due_on = p_since
            order by coalesce(tried_on, created_on), created_at loop
    select min(x) into best from unnest(slots) x
     where x <= r.t and x > coalesce((select max(f) from unnest(filled) f), -1);
    if best is not null then filled := filled || best; end if;
    if r.again is not null then
      select max(x) into best from unnest(slots) x where x <= r.again and x <> all (filled);
      if best is not null then filled := filled || best; end if;
    end if;
  end loop;
  return (select min(x) from unnest(slots) x where x > coalesce((select max(f) from unnest(filled) f), -1));
end $$;
revoke all on function private.billing_try_slot(uuid, date) from public, anon, authenticated;

-- 0120's failed. A renewal for a date already paid, or for an account now Free or
-- comped, changes nothing but the charge: a retry declined after the user settled.
create or replace function public.billing_charge_failed(p_reference text, p_error text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  s int;
  next_try date;
  today date := private.billing_today();
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then raise exception 'unknown reference' using errcode = 'P0002'; end if;
  -- applied: false for a payment marked for refund, so /verify does not call it paid.
  if c.status <> 'pending' then
    return jsonb_build_object('status', c.status, 'again', true, 'kind', c.kind,
                              'applied', not coalesce(c.error like 'refund%', false));
  end if;
  perform private.billing_lock(c.user_id);
  select * into b from private.billing where user_id = c.user_id for update;
  update private.billing_charges set status = 'failed', error = left(p_error, 300), settled_at = now()
   where reference = p_reference;
  if c.kind <> 'renewal' then return jsonb_build_object('status', 'failed'); end if;
  if b.plan is null or b.plan = 'free' or b.comped
     or exists (select 1 from private.billing_charges x
                 where x.user_id = c.user_id and x.kind in ('renewal', 'settle') and x.due_on = c.due_on
                   and x.status = 'paid' and x.error is null) then
    return jsonb_build_object('status', 'failed', 'owed', false);
  end if;

  update private.billing set state = 'past_due', past_due_since = coalesce(past_due_since, c.due_on), updated_at = now()
   where user_id = c.user_id
  returning * into b;
  s := private.billing_try_slot(c.user_id, b.past_due_since);
  next_try := case when s is not null then greatest(b.past_due_since + s, today + 1) end;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (c.user_id, 'bill_failed', 'bill:' || p_reference,
          jsonb_build_object('plan', c.plan, 'period', c.period, 'amount', c.amount,
            'card', private.billing_card_label(b.card), 'nextTry', next_try,
            'freeOn', greatest(b.past_due_since + 8, coalesce(next_try + 1, today + 1))),
          1)
  on conflict do nothing;
  return jsonb_build_object('status', 'failed', 'nextTry', next_try);
end $$;

-- ---------------------------------------------------------------------------
-- 5. Refunds
-- ---------------------------------------------------------------------------
-- A refund that failed is written in front of the reason the charge was marked for:
-- "refund failed: <why> | <reason>". These two read it back.
create or replace function private.billing_refund_reason(p_error text)
returns text language sql immutable as $$
  select case when p_error like 'refund failed: %' then
           case when position(' | ' in p_error) > 0 then substr(p_error, position(' | ' in p_error) + 3) end
         else p_error end
$$;
create or replace function private.billing_refund_note(p_error text, p_why text)
returns text language sql immutable as $$
  select left('refund failed: ' || p_why || coalesce(' | ' || private.billing_refund_reason(p_error), ''), 300)
$$;
revoke all on function private.billing_refund_reason(text), private.billing_refund_note(text, text) from public, anon, authenticated;

-- "R… is on its way back to your card": once per payment marked for refund, whichever
-- of our refund call and Paystack's refund event comes first. Not for the R1.
create or replace function private.billing_refund_mail(c private.billing_charges)
returns void language sql set search_path = public, private, pg_temp as $$
  insert into public.email_queue (user_id, kind, key, data, priority)
  select c.user_id, 'bill_refund', 'bill_refund:' || c.reference,
         jsonb_build_object('amount', c.amount, 'reference', c.reference,
           'date', (c.settled_at at time zone 'Africa/Johannesburg')::date,
           'why', case when c.error like '%price changed%' then 'price' else 'changed' end),
         1
   where c.kind <> 'card' and c.status = 'paid' and c.error like 'refund%'
  on conflict do nothing
$$;
revoke all on function private.billing_refund_mail(private.billing_charges) from public, anon, authenticated;

-- We asked Paystack for the refund of a card change's R1 or of a payment marked for
-- refund. p_error: Paystack refused it; the daily run asks again, once a day, 7 times,
-- then hello@ is told. Taken: the user gets the refund email (not for the R1).
create or replace function public.billing_charge_refunded(p_reference text, p_error text default null)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare c private.billing_charges;
begin
  update private.billing_charges
     set refund_status = case when p_error is null then 'asked' else 'failed' end,
         refunded_at = case when p_error is null then now() end,
         refund_tries = refund_tries + 1, refund_tried_at = now(),
         error = case when p_error is null then private.billing_refund_reason(error)
                      else private.billing_refund_note(error, p_error) end
   where reference = p_reference and status = 'paid' and (kind = 'card' or error like 'refund%')
     and coalesce(refund_status, 'failed') = 'failed'
  returning * into c;
  if not found then return; end if;
  if p_error is null then
    perform private.billing_refund_mail(c);
    return;
  end if;
  raise warning 'billing refund % refused: %', p_reference, p_error;
  if c.refund_tries >= 7 then
    insert into public.email_queue (to_email, kind, key, data, priority)
    values ('hello@princesolarhub.co.za', 'bill_mail_failed', 'bill_refund_stuck:' || p_reference,
            jsonb_build_object('kind', 'refund refused 7 times: refund it by hand', 'key', p_reference,
              'user', c.user_id, 'error', left(p_error, 300)), 1)
    on conflict do nothing;
  end if;
end $$;

-- Paystack's refund events. p_status: pending, processing, processed, failed. p_cents:
-- the refund's amount; p_refund: its id. Also refunds made by hand in Paystack's
-- dashboard: recorded with their amount, off Billing's payment list, the plan kept.
-- Answers false for a reference we never made.
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

-- Refunds to ask Paystack for again: refused, or never asked (the function stopped
-- between the payment and the refund). An hour after the payment, then once a day (the
-- run's calls are 5 minutes apart), up to 7 tries.
create or replace function public.billing_refunds_due()
returns setof text language sql stable security definer set search_path = public, private, pg_temp as $$
  select reference from private.billing_charges
   where status = 'paid' and (kind = 'card' or error like 'refund%')
     and coalesce(refund_status, 'failed') = 'failed' and refund_tries < 7
     and settled_at < now() - interval '1 hour'
     and (refund_tried_at is null or refund_tried_at < now() - interval '20 hours')
   order by settled_at
   limit 200
$$;
revoke all on function public.billing_refunds_due() from public, anon, authenticated;
grant execute on function public.billing_refunds_due() to service_role;

-- ---------------------------------------------------------------------------
-- 6. Disputes
-- ---------------------------------------------------------------------------
-- Paystack's charge.dispute.* events. The dispute's status is written on the charge.
-- Lost (the bank took the money back): an unpaid renewal from today, so past due,
-- retried on day 1, 3 and 7, Free on day 8. Once per charge.
create or replace function public.billing_charge_disputed(p_reference text, p_status text, p_lost boolean,
  p_cents bigint default null)
returns boolean language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  ref text := 'psh_' || replace(gen_random_uuid()::text, '-', '');
  today date := private.billing_today();
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then return false; end if;
  perform private.billing_lock(c.user_id);
  update private.billing_charges set dispute = left(coalesce(p_status, 'open'), 60) where reference = p_reference;
  if not p_lost or c.dispute_lost then return true; end if;
  update private.billing_charges
     set dispute_lost = true, refund_status = 'done', refunded_at = coalesce(refunded_at, now()),
         refunded_cents = coalesce(p_cents, amount * 100::bigint)
   where reference = p_reference;
  raise warning 'billing charge % disputed and lost', p_reference;
  -- Money that applied nothing, or a card check, takes nothing away.
  if c.status <> 'paid' or c.kind = 'card' or c.amount = 0 or c.error is not null then return true; end if;
  select * into b from private.billing where user_id = c.user_id for update;
  if b.plan is null or b.plan = 'free' or b.comped or b.state = 'past_due' then return true; end if;
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on, tried_on,
                                       status, error, settled_at)
  values (ref, c.user_id, 'renewal', b.plan, b.period, c.amount, today, today, today,
          'failed', 'dispute lost: ' || p_reference, now());
  update private.billing set state = 'past_due', past_due_since = today, updated_at = now() where user_id = c.user_id;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (c.user_id, 'bill_failed', 'bill:' || ref,
          jsonb_build_object('plan', b.plan, 'period', b.period, 'amount', c.amount,
            'card', private.billing_card_label(b.card), 'nextTry', today + 1, 'freeOn', today + 8,
            'disputed', (c.settled_at at time zone 'Africa/Johannesburg')::date),
          1)
  on conflict do nothing;
  return true;
end $$;
revoke all on function public.billing_charge_disputed(text, text, boolean, bigint) from public, anon, authenticated;
grant execute on function public.billing_charge_disputed(text, text, boolean, bigint) to service_role;

-- ---------------------------------------------------------------------------
-- 7. The daily run (0128's), catching up missed days
-- ---------------------------------------------------------------------------
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
    update private.billing_charges set created_on = greatest(created_on, today) where reference = c.reference;
    if c.tried_on <= today - 3 then
      perform public.billing_charge_failed(c.reference, 'not settled at Paystack 3 days after the first try');
      continue;
    end if;
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

  -- Booked removals due today, or missed.
  for b in select * from private.billing where remove_on <= today and cardinality(plants_to_remove) > 0 loop
    foreach p in array b.plants_to_remove loop perform private.billing_drop_plant(b.user_id, p); end loop;
    update private.billing set plants_to_remove = '{}', remove_on = null, updated_at = now() where user_id = b.user_id;
  end loop;

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

-- ---------------------------------------------------------------------------
-- 8. Delete account, comped switch
-- ---------------------------------------------------------------------------
-- 0102's delete, refused while money is owed or a paid plan runs on. A plan with its
-- cancel booked may go: it runs to its billing date, nothing is refunded.
create or replace function public.api_account_delete()
returns jsonb
language plpgsql
security definer
set search_path = public, private, vault, pg_temp
as $$
declare
  uid uuid := auth.uid();
  b private.billing;
  acc record;
  p bigint;
  mine bigint[];
  orphans bigint[];
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  -- Charge rows before the user lock, as billing_charge_paid takes them.
  perform 1 from private.billing_charges where user_id = uid order by reference for update;
  perform private.billing_lock(uid);
  select * into b from private.billing where user_id = uid for update;
  if b.state = 'past_due' then
    raise exception 'pay what is owed first' using errcode = '22023';
  end if;
  if exists (select 1 from private.billing_charges
              where user_id = uid and status = 'pending' and kind in ('start', 'upgrade', 'settle')
                and created_at > now() - interval '1 day') then
    raise exception 'a payment is open' using errcode = '22023';
  end if;
  -- Money still to go back: the charge row it needs goes with the account.
  if exists (select 1 from private.billing_charges
              where user_id = uid and status = 'paid' and (kind = 'card' or error like 'refund%')
                and coalesce(refund_status, 'failed') = 'failed') then
    raise exception 'a payment is open' using errcode = '22023';
  end if;
  if b.plan <> 'free' and not b.comped and b.next_plan is distinct from 'free' then
    raise exception 'cancel your plan first' using errcode = '22023';
  end if;

  for acc in select id from private.sunsynk_accounts where user_id = uid order by id loop
    perform pg_advisory_xact_lock(1, hashtext(acc.id::text));
  end loop;
  select coalesce(array_agg(plant_id order by plant_id), '{}') into mine
    from public.plant_users where user_id = uid;
  foreach p in array mine loop perform pg_advisory_xact_lock(p); end loop;
  select coalesce(array_agg(g order by g), '{}') into orphans
    from unnest(mine) g
   where not exists (select 1 from public.plant_users o where o.plant_id = g and o.user_id <> uid);

  for acc in select id, refresh_secret_id from private.sunsynk_accounts where user_id = uid loop
    if acc.refresh_secret_id is not null then delete from vault.secrets where id = acc.refresh_secret_id; end if;
    update private.inverters set account_id = null where account_id = acc.id;
  end loop;
  delete from private.sunsynk_accounts where user_id = uid;

  delete from public.plant_users where user_id = uid;
  perform private.plants_tombstone(orphans);

  insert into public.email_queue (to_email, kind, key, priority)
  select email, 'account_deleted', 'account_deleted:' || uid, 1 from auth.users where id = uid and email is not null
  on conflict do nothing;

  delete from public.profiles where user_id = uid;
  delete from auth.users where id = uid;
  return jsonb_build_object('deleted', true, 'plantsRemoved', coalesce(array_length(orphans, 1), 0));
end $$;
revoke all on function public.api_account_delete() from public, anon;
grant execute on function public.api_account_delete() to authenticated, service_role;

-- Comped on or off, by hand (Brynne, from the SQL editor):
--   select public.billing_set_comped('<user id>', true);
-- On: Family free of charge, no limit, nothing booked; open charges paid later are
-- refunded (stale), renewals are closed. Off: Free, plants fitted to its 1 (the first
-- linked keeps collecting), and the free week counted from the first link, so Free trims.
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
          state = 'active', past_due_since = null, plants_to_remove = '{}', remove_on = null, updated_at = now();
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
revoke all on function public.billing_set_comped(uuid, boolean) from public, anon, authenticated;
grant execute on function public.billing_set_comped(uuid, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- 9. What the app reads
-- ---------------------------------------------------------------------------
-- 0129's quote. dueNow is null where billing_charge_open refuses the payment: comped,
-- past due ("refused": past_due), or more extras with a plan change booked (plan_change).
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
  q := public.billing_upgrade_quote(auth.uid(), p_plan, added, case when coalesce(b.plan, 'free') = 'free' then p_period end);
  why := case when coalesce(b.comped, false) then 'comped'
              when b.state = 'past_due' then 'past_due'
              when b.next_plan is not null and p_plan = b.plan and added > 0 then 'plan_change' end;
  if why is not null then q := q || jsonb_build_object('dueNow', null, 'refused', why); end if;
  return jsonb_build_object('plan', coalesce(b.plan, 'free'), 'period', b.period,
           'extraPlants', coalesce(b.extra_plants, 0),
           'extraPrice', public.billing_amount('family', coalesce(b.period, p_period), 1)
                         - public.billing_amount('family', coalesce(b.period, p_period), 0))
      || q;
end $$;

-- 0129's status: payments refunded (in part or in full, by us or by hand) leave the list.
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

-- ---------------------------------------------------------------------------
-- 10. A bill email that fails after its last try alerts hello@ (0102's email_done)
-- ---------------------------------------------------------------------------
create or replace function public.email_done(p_results jsonb)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.email_queue q
     set status     = r.status,
         last_error = r.error,
         sent_at    = case when r.status = 'sent' then now() end,
         claimed_at = null,
         batch_key  = coalesce(r.batch_key, q.batch_key),
         tries      = q.tries - case when r.refund then 1 else 0 end,
         due_at     = case when r.status = 'queued' then now() + make_interval(secs => coalesce(r.retry_s, 60)) else q.due_at end
    from jsonb_to_recordset(p_results) as r(id bigint, status text, error text, retry_s int, batch_key text, refund boolean)
   where q.id = r.id and q.status = 'sending' and r.status in ('sent', 'queued', 'failed', 'skipped');
  -- The user never heard about their money: tell Brynne (hello@ is her inbox).
  insert into public.email_queue (to_email, kind, key, data, priority)
  select 'hello@princesolarhub.co.za', 'bill_mail_failed', 'bill_mail_failed:' || q.id,
         jsonb_build_object('kind', q.kind, 'key', q.key, 'user', q.user_id, 'error', left(q.last_error, 300)), 1
    from public.email_queue q
    join jsonb_to_recordset(p_results) as r(id bigint, status text) on r.id = q.id
   where r.status = 'failed' and q.status = 'failed' and q.kind like 'bill\_%' and q.kind <> 'bill_mail_failed'
  on conflict do nothing;
  delete from public.email_queue where kind in ('account_deleted', 'bill_mail_failed') and status in ('sent', 'failed', 'skipped');
$$;
revoke all on function public.email_done(jsonb) from public, anon, authenticated;
grant execute on function public.email_done(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 11. Gone
-- ---------------------------------------------------------------------------
drop function if exists public.billing_set_paused(uuid, bigint[], boolean);

do $$
declare f text;
begin
  foreach f in array array['billing_renew(uuid)', 'billing_book_change(uuid, text, text)',
                           'billing_settle_open(uuid)', 'billing_card_open(uuid)',
                           'billing_charge_failed(text, text)', 'billing_charge_refunded(text, text)',
                           'billing_run(date)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['api_plant_start(bigint)', 'api_billing_keep(bigint)', 'api_billing_extras(int)',
                           'api_billing_quote(text, text, int)', 'api_billing_status()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
