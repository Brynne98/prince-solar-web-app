-- ============================================================================
-- 0120 — change card, and what Account shows of payments (SOLAR-238).
--
-- Paystack saves a card only after a payment on it. Change card is a R1 charge on
-- Paystack's card page (kind 'card'): when it is paid the new card replaces the old
-- one, nothing else changes, and the billing function refunds the R1 at once.
--
-- api_billing_status also gives the app the saved card (brand, last 4, expiry), the
-- last payments, and the list prices for both periods, so Account can show every
-- plan side by side.
-- ============================================================================

alter table private.billing_charges drop constraint if exists billing_charges_kind_check;
alter table private.billing_charges add constraint billing_charges_kind_check
  check (kind in ('start', 'upgrade', 'renewal', 'settle', 'card'));
-- card: when the R1 went back to the card
alter table private.billing_charges add column if not exists refunded_at timestamptz;

-- Open a card change for a paying user. Returns {reference, amount, email}; the
-- function always sends it to the card page.
create or replace function public.billing_card_open(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  ref text := 'psh_' || replace(gen_random_uuid()::text, '-', '');
begin
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' or b.comped then
    raise exception 'no card to change' using errcode = '22023';
  end if;
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on)
  values (ref, p_user, 'card', b.plan, b.period, 1, private.billing_today(), private.billing_today());
  return jsonb_build_object('reference', ref, 'amount', 1,
    'email', (select email from auth.users where id = p_user));
end $$;

-- 0116's billing_charge_paid, with the card kind: the card is saved, nothing else
-- is applied, no email. The answer says {refund: true} for a card charge not yet
-- refunded, so a second report (webhook after the return, or the other way round)
-- retries a refund that failed.
create or replace function public.billing_charge_paid(p_reference text, p_card jsonb default null,
  p_quiet boolean default false, p_cents bigint default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  today date := private.billing_today();
  v_from text;
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
  v_from := coalesce(b.plan, 'free');
  -- Paid on a card page opened earlier, but the account has moved on since: a second
  -- start, an upgrade after a move to Free or a failed renewal, a second settle. Paystack has the
  -- money; nothing is applied. The error marks it for a refund from Paystack's dashboard.
  if (c.kind = 'start' and v_from <> 'free')
     or (c.kind = 'upgrade' and (v_from = 'free' or b.state = 'past_due' or b.period is distinct from c.period))
     or (c.kind = 'settle' and b.state is distinct from 'past_due') then
    update private.billing_charges set status = 'paid', settled_at = now(),
           error = 'refund: paid after the account changed (' || v_from || ', ' || coalesce(b.state, 'active') || ')'
     where reference = p_reference;
    raise warning 'billing charge % paid but not applied: refund it', p_reference;
    return jsonb_build_object('status', 'paid', 'applied', false, 'kind', c.kind);
  end if;
  update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;

  if c.kind = 'start' then
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
    values (c.user_id, c.plan, c.period, extract(day from today)::int,
            public.billing_step(today, c.period, extract(day from today)::int, 1))
    on conflict (user_id) do update
      set plan = excluded.plan, period = excluded.period, billing_day = excluded.billing_day,
          next_billing_date = excluded.next_billing_date, next_plan = null, next_period = null,
          state = 'active', past_due_since = null, updated_at = now();
  elsif c.kind = 'upgrade' then
    update private.billing set plan = c.plan, next_plan = null, updated_at = now()
     where user_id = c.user_id;
  else  -- renewal, settle
    update private.billing set state = 'active', past_due_since = null, updated_at = now() where user_id = c.user_id;
  end if;
  if c.kind in ('start', 'upgrade') then
    perform private.billing_resume(c.user_id, c.plan, c.added);
  end if;
  if p_card is not null and coalesce((p_card->>'reusable')::boolean, false) then
    update private.billing set card = p_card, card_email = (select email from auth.users where id = c.user_id)
     where user_id = c.user_id;
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
              'extra', public.billing_extra_inverters(c.user_id),
              'extraEach', public.billing_amount('family', b.period, 1) - public.billing_amount('family', b.period, 0),
              'nextAmount', public.billing_amount_due(c.user_id), 'nextDate', b.next_billing_date),
            1)
    on conflict do nothing;
  end if;
  return jsonb_build_object('status', 'paid', 'plan', b.plan, 'kind', c.kind);
end $$;

-- 0116's billing_charge_failed; a report on a charge already settled names its kind,
-- so a refunded (reversed) card change still reads as paid.
create or replace function public.billing_charge_failed(p_reference text, p_error text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  try_day int;
  next_try date;
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then raise exception 'unknown reference' using errcode = 'P0002'; end if;
  if c.status <> 'pending' then return jsonb_build_object('status', c.status, 'again', true, 'kind', c.kind); end if;
  update private.billing_charges set status = 'failed', error = left(p_error, 300), settled_at = now()
   where reference = p_reference;
  if c.kind <> 'renewal' then return jsonb_build_object('status', 'failed'); end if;

  update private.billing set state = 'past_due', past_due_since = coalesce(past_due_since, c.due_on), updated_at = now()
   where user_id = c.user_id
  returning * into b;
  try_day := c.created_on - b.past_due_since;
  next_try := b.past_due_since + case when try_day < 1 then 1 when try_day < 3 then 3 when try_day < 7 then 7 end;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (c.user_id, 'bill_failed', 'bill:' || p_reference,
          jsonb_build_object('plan', c.plan, 'period', c.period, 'amount', c.amount,
            'card', private.billing_card_label(b.card), 'nextTry', next_try, 'freeOn', b.past_due_since + 8),
          1)
  on conflict do nothing;
  return jsonb_build_object('status', 'failed', 'nextTry', next_try);
end $$;

-- The R1 went back. p_error: Paystack refused the refund (logged on the charge).
create or replace function public.billing_charge_refunded(p_reference text, p_error text default null)
returns void language sql security definer set search_path = public, private, pg_temp as $$
  update private.billing_charges
     set refunded_at = case when p_error is null then now() end,
         error = case when p_error is null then error else left('refund failed: ' || p_error, 300) end
   where reference = p_reference and kind = 'card' and refunded_at is null;
$$;

-- 0113's api_billing_status, plus card, payments and prices.
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
    'price', public.billing_amount(coalesce(b.plan, 'free'), b.period, public.billing_extra_inverters(auth.uid())),
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

revoke all on function public.billing_card_open(uuid), public.billing_charge_refunded(text, text) from public, anon, authenticated;
grant execute on function public.billing_card_open(uuid), public.billing_charge_refunded(text, text) to service_role;
revoke all on function public.billing_charge_paid(text, jsonb, boolean, bigint), public.billing_charge_failed(text, text)
  from public, anon, authenticated;
grant execute on function public.billing_charge_paid(text, jsonb, boolean, bigint), public.billing_charge_failed(text, text)
  to service_role;
