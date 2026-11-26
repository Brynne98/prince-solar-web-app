CREATE OR REPLACE FUNCTION billing.payment_reminder_check(p_account uuid, p_inv uuid, p_at timestamp with time zone, OUT stop text, OUT wait text)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  st billing.status;
  inv billing.invoices;
  rs jsonb;
  tz text;
  h record;
begin
  select * into inv from billing.invoices where id = p_inv and account = p_account;
  if inv.id is null or inv.kind <> 'renewal' then stop := 'no renewal bill'; return; end if;
  if inv.status <> 'open' then stop := 'bill settled'; return; end if;
  st := billing.account_status(p_account, p_at);
  if st.state <> 'past_due' then stop := 'not past due'; return; end if;
  if st.plan_ends_at <= p_at then stop := 'past the pay-by date'; return; end if;
  rs := billing.renewal_state(p_account, p_at, st);
  if rs->'due_bill'->>'id' is distinct from inv.id::text then stop := 'a later bill'; return; end if;
  if rs->>'next_try_on' is not null then stop := 'a try is coming'; return; end if;
  if exists (select 1 from billing.outbox o where o.invoice = inv.id and o.key in ('payment_failed', 'card_update', 'payment_due')
                and o.status = 'sent' and o.sent_at > p_at - interval '3 days') then
    stop := 'payment email sent'; return;
  end if;
  select coalesce(a.time_zone, m.default_time_zone) into tz
    from billing.accounts a join billing.markets m on m.code = a.market where a.id = p_account;
  if p_at < (((st.plan_ends_at at time zone tz)::date - 3) + time '08:00') at time zone tz then
    wait := 'too early'; return;
  end if;

  select * into h from billing.renewal_hold(p_account, p_at);
  if h.in_flight or exists (select 1 from billing.payment_attempts pa where pa.invoice = inv.id and pa.channel = 'card_page'
                               and pa.status in ('created', 'pending', 'unknown') and pa.replaced_at is null
                               and pa.created_at > p_at - interval '1 hour') then
    wait := 'payment under way'; return;
  end if;
  if exists (select 1 from billing.outbox o where o.invoice = inv.id and o.key in ('payment_failed', 'card_update', 'payment_due')
                and o.status = 'queued') then
    wait := 'payment email waiting'; return;
  end if;
  -- the daily run (billing-run, */5 4-5 UTC, billing.next_run_at) may be charging the card now
  if (billing.active_method(p_account)).id is not null
     and (p_at at time zone 'UTC')::time >= time '04:00' and (p_at at time zone 'UTC')::time < time '06:05' then
    wait := 'billing run'; return;
  end if;
end $function$;
