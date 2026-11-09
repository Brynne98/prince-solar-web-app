-- ============================================================================
-- 0171: a refund made by hand in the Paystack dashboard emails the user (SOLAR-444).
--
-- Decided 2026-10-31: the user gets a refund email, and the plan stays.
-- billing_refund_mail queued only our own refunds (charge error "refund..."). A
-- hand refund leaves the error alone, so nothing was queued.
--
-- Now a hand refund queues one bill_refund per refund once Paystack reports it
-- processed (the amount is known then), with why 'hand', the amount refunded (a
-- partial refund too, in rand with cents) and what was paid. Key per refund id,
-- so Paystack's replays queue nothing new and a second partial refund gets its own.
-- Our own refunds are as before. The R1 card check is never emailed.
-- ============================================================================

create or replace function private.billing_refund_mail(c private.billing_charges)
returns void language sql set search_path = public, private, pg_temp as $$
  insert into public.email_queue (user_id, kind, key, data, priority)
  select c.user_id, 'bill_refund', 'bill_refund:' || c.reference,
         jsonb_build_object('amount', c.amount, 'reference', c.reference,
           'date', (c.settled_at at time zone 'Africa/Johannesburg')::date,
           'why', case when c.error like '%price changed%' then 'price' else 'changed' end),
         1
   where c.kind <> 'card' and c.status = 'paid' and c.error like 'refund%'
  union all
  -- by hand: the refunds as recorded now (refund_event writes them before it calls this)
  select c.user_id, 'bill_refund', 'bill_refund:' || c.reference || ':' || r.key,
         jsonb_build_object('amount', round(r.value::numeric / 100, 2), 'paid', c.amount, 'reference', c.reference,
           'date', (c.settled_at at time zone 'Africa/Johannesburg')::date, 'why', 'hand'),
         1
    from private.billing_charges x, jsonb_each_text(x.refunds) r
   where x.reference = c.reference
     and c.kind <> 'card' and c.status = 'paid' and coalesce(c.error, '') not like 'refund%'
  on conflict do nothing
$$;
