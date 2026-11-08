-- ============================================================================
-- 0168 — a past-due account with no failed renewal does not stop the daily run (SOLAR-437).
--
-- The retry step read the failed renewal of the past-due date and copied its plan, period
-- and amount. An account set past due with no such renewal (by hand, or a test script)
-- found none and inserted a charge with no plan: the not-null check raised and the whole
-- run rolled back, every other account's renewal with it. No app path makes that state.
-- Now: nothing to retry, so no retry; on day 8 the account moves to Free as after the last
-- try. Body is 0133's with only the two marked lines changed.
-- ============================================================================
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
    -- no failed renewal to retry counts as the tries made (0168)
    if private.billing_try_slot(b.user_id, b.past_due_since) is null
       or not exists (select 1 from private.billing_charges x where x.user_id = b.user_id and x.kind = 'renewal'
                       and x.due_on = b.past_due_since) then
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
    continue when not found;  -- nothing to retry (0168)
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
