CREATE OR REPLACE FUNCTION billing.outbox_take(p_limit integer DEFAULT 50, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  o billing.outbox;
  why text;
  out jsonb := '[]';
  inv billing.invoices;
  att billing.payment_attempts;
  pm billing.payment_methods;
  u record;
begin
  -- before the switch the old emails still go; these wait and go once it is on
  if not billing.is_live() then return '[]'::jsonb; end if;
  for o in select * from billing.outbox
            where status = 'queued' and not_before <= p_at and (claimed_until is null or claimed_until <= p_at)
              -- held, not dropped: a renewal paid before the cutoff may still be answered (0248)
              and not case when key = 'plan_ended' then billing.plan_ended_held(account, ref, p_at)
                              when key = 'payment_reminder' then                                 -- 0276
                                (select c.stop is null and c.wait is not null
                                   from billing.payment_reminder_check(account, invoice, p_at) c)
                              else false end
            order by not_before, id limit p_limit for update skip locked loop
    why := billing.outbox_guard(o, p_at);
    if why is not null then
      update billing.outbox set status = 'dropped', drop_reason = why, claimed_until = null where id = o.id;
      continue;
    end if;
    select au.id, au.email, ep.unsub_token into u
      from billing.accounts a join auth.users au on au.id = a.user_id
      left join public.email_prefs ep on ep.user_id = au.id where a.id = o.account;
    if u.email is null then
      update billing.outbox set status = 'dropped', drop_reason = 'no email', claimed_until = null where id = o.id;
      continue;
    end if;
    -- 0281 (SOLAR-679 F13): bounced for good or marked as spam; never sent, so never tried again
    if private.mail_blocked(u.email) then
      update billing.outbox set status = 'dropped', drop_reason = 'address blocked', claimed_until = null where id = o.id;
      continue;
    end if;
    inv := null; att := null; pm := null;
    if o.invoice is not null then
      select * into inv from billing.invoices where id = o.invoice;
      select * into att from billing.payment_attempts where invoice = inv.id and status in ('success', 'failed')
       order by (status = 'success') desc, created_at desc limit 1;
      -- a failed or refused try's email names that try's card; card_update rows queued before
      -- 0248 have no ref: the latest refused saved-card try on the bill
      if o.key in ('payment_failed', 'card_update', 'payment_due') then
        select * into att from billing.payment_attempts where invoice = inv.id and id::text = o.ref;
        if att.id is null and o.key = 'card_update' then
          select * into att from billing.payment_attempts where invoice = inv.id and channel = 'saved_card' and hard_decline
           order by created_at desc limit 1;
        end if;
      end if;
      if att.payment_method is not null then select * into pm from billing.payment_methods where id = att.payment_method; end if;
    end if;
    update billing.outbox set claimed_until = p_at + interval '5 minutes', tries = tries + 1 where id = o.id;
    out := out || jsonb_build_array(jsonb_build_object(
      'id', o.id, 'key', o.key, 'user', u.id, 'email', u.email,
      -- a reminder always carries its unsubscribe link: the settings row is made if missing
      'unsub_token', case when (select reminder from billing.outbox_kinds where key = o.key)
                          then public.email_unsub_token(u.id) else u.unsub_token end,
      'reminder', (select reminder from billing.outbox_kinds where key = o.key),
      'state', billing.screen_state(o.account, p_at),
      -- the frozen bill a receipt reads
      'bill', case when inv.id is not null then jsonb_build_object(
                'kind', inv.kind, 'plan', inv.plan, 'plan_name', inv.plan_name,
                'interval', inv.interval, 'amount_minor', inv.amount_minor, 'currency', inv.currency,
                'next_amount_minor', case when inv.next_interval is not null
                  then (select np.amount_minor + inv.extra_places * np.extra_place_minor
                          from billing.price_keeping_offer(inv.plan, (select market from billing.accounts where id = inv.account),
                                                           inv.next_interval, inv.offer, inv.paid_at) np)
                  else inv.plan_amount_minor + inv.extra_places * inv.extra_place_minor end,
                'starts_now', inv.kind = 'upgrade' and inv.period_key like '%@%',
                'period_start', inv.period_start, 'period_end', inv.period_end, 'paid_at', inv.paid_at,
                'reference', att.reference, 'card_type', pm.card_type, 'last4', pm.last4) end,
      'refund', (select jsonb_build_object('amount_minor', coalesce(r.amount_minor, pa.amount_minor), 'currency',
                         coalesce(r.currency, pa.currency), 'reference', r.reference, 'reason', r.reason,
                         'paid_at', pa.settled_at, 'paid_minor', pa.amount_minor,
                         -- the card the refunded payment came from, not the one saved now
                         'card_type', rpm.card_type, 'last4', rpm.last4)
                   from billing.refunds r left join billing.payment_attempts pa on pa.id = r.attempt
                   left join billing.payment_methods rpm on rpm.id = pa.payment_method
                  where o.key = 'refund' and r.id = o.ref::uuid),
      -- a plan's end: its date, why, and whether a renewal payment was never answered
      'ended', case when o.key = 'plan_ended' then billing.plan_ended_facts(o) end,
      'event', (select jsonb_build_object('kind', e.kind, 'before', e.before, 'after', e.after)
                  from billing.account_events e where o.key in ('change_booked', 'change_undone') and e.id = o.ref::bigint),
      'plant', (select jsonb_build_object('id', p.id, 'name', coalesce((select lp.plant_name from plants.list_info lp
                         join plants.login_info l on l.id = lp.login where l.account = o.account and lp.plant = p.id limit 1),
                         (select pu.plant_name from plants.user_plants pu where pu.plant_id = p.id and pu.user_id = u.id limit 1)))
                  from plants.plant_info p where o.key = 'history_deleted' and p.id = o.ref::bigint)));
  end loop;
  return out;
end $function$;
