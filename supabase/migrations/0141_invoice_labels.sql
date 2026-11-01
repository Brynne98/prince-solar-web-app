-- SOLAR-302: every Invoices row says what was paid for. Billing's payments list gains
-- added (extra plants bought by this charge), extra (extra plants paid for in all) and
-- prev (the plan of the payment before). Body is 0138's api_billing_status with only
-- the payments list changed.

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
    'prices', jsonb_build_object(
      'monthly', jsonb_build_object('home', public.billing_amount('home', 'monthly'), 'family', public.billing_amount('family', 'monthly'),
                   'extra', public.billing_amount('family', 'monthly', 1) - public.billing_amount('family', 'monthly')),
      'yearly', jsonb_build_object('home', public.billing_amount('home', 'yearly'), 'family', public.billing_amount('family', 'yearly'),
                   'extra', public.billing_amount('family', 'yearly', 1) - public.billing_amount('family', 'yearly'))));
end $$;
