-- ============================================================================
-- 0184 — Invoices keep every payment (SOLAR-489).
--
-- api_billing_status 'payments' listed paid, unrefunded charges with no error note.
-- A refund made the row go, and with it the whole Invoices section when it was the
-- only payment. A charge paid with a card that could not be saved ('card not
-- reusable: not saved') was hidden too, though it applied.
--
-- Now: every paid charge that took money (not a card check), whatever its refund or
-- error note, with a status:
--   refunded       Paystack took or paid out a refund of the whole amount
--   part_refunded  paid out less than the amount
--   paid           anything else
-- A lost dispute is written as a refund (0132), so it reads refunded too. An open or
-- won dispute stays paid: the customer is not shown disputes (decided 2026-11-11).
-- prev only counts charges that applied: one refunded because it applied nothing
-- (error 'refund: ...') must not turn the next payment into an "upgrade".
-- Body is 0145's with only 'payments' changed.
-- ============================================================================

-- prices: at the account's offer (quoted on Free, held on a paid plan); listPrices: list;
-- offer: its terms, or null. price: the plan held, at the offer held today.
-- nextTry and freeOn are back (0132): 0138 dropped them and Billing's past-due line read
-- "Pay by" with no date.
create or replace function public.api_billing_status()
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  v_offer text := private.billing_offer_now(auth.uid());
  slot int;
  next_try date;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid();
  -- past due: the next day the run tries the card (the morning run; tomorrow once today's is made),
  -- and Free the day after the last try, day 8 at the earliest (as bill_failed says)
  if b.state = 'past_due' then
    slot := private.billing_try_slot(b.user_id, b.past_due_since);
    next_try := case when slot is not null then greatest(b.past_due_since + slot, private.billing_today()
      + case when exists (select 1 from private.billing_charges x where x.user_id = b.user_id and x.kind = 'renewal'
                           and x.created_on = private.billing_today()) then 1 else 0 end) end;
  end if;
  return jsonb_build_object(
    'nextTry', next_try,
    'freeOn', case when b.state = 'past_due' then greatest(b.past_due_since + 8, next_try + 1) end,
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
                           'added', coalesce(c.added, 0), 'extra', coalesce(c.extra_plants, 0),
                           'prev', (select x.plan from private.billing_charges x
                                     where x.user_id = c.user_id and x.status = 'paid' and x.kind <> 'card' and x.amount > 0
                                       and coalesce(x.error, '') not like 'refund%' and x.settled_at < c.settled_at
                                     order by x.settled_at desc limit 1),
                           'status', case when coalesce(c.refund_status, 'failed') = 'failed' then 'paid'
                                          when c.refunded_cents < c.amount * 100::bigint then 'part_refunded'
                                          else 'refunded' end) p
                    from private.billing_charges c
                   where c.user_id = auth.uid() and c.status = 'paid' and c.kind <> 'card' and c.amount > 0
                   order by c.settled_at desc limit 6) x), '[]'::jsonb),
    'prices', private.billing_price_list(v_offer),
    'listPrices', private.billing_price_list(null),
    'offer', private.billing_offer_json(v_offer, auth.uid()));
end $$;
