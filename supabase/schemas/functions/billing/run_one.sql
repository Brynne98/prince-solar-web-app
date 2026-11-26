CREATE OR REPLACE FUNCTION billing.run_one(p_sub uuid, p_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  s billing.subscriptions;
  m billing.markets;
  inv billing.invoices;
  pm billing.payment_methods;
  att billing.payment_attempts;
  due_from timestamptz;
  tz text;
  cut timestamptz;
begin
  select * into s from billing.subscriptions where id = p_sub;
  perform billing.lock_account(s.account);
  select * into s from billing.subscriptions where id = p_sub for update;
  if s.status not in ('active', 'past_due') then return null; end if;
  select mk.* into m from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = s.account;
  tz := coalesce((select a.time_zone from billing.accounts a where a.id = s.account), m.default_time_zone);
  cut := billing.past_due_cutoff(s.past_due_since, m.retry_days, tz);

  -- the clock had ended these already: no version bump, so a restart checkout stays good
  if s.cancel_at_period_end and s.period_end <= p_at then
    perform billing.end_sub(s.id, s.period_end, 'cancelled', p_at, 'job', false);
    return jsonb_build_object('step', 'ended', 'reason', 'cancelled');
  end if;
  if s.status = 'past_due' and p_at >= cut then
    -- a payment made before the cutoff may still land (or its page is not verified yet: this
    -- run's verify comes after): the next run looks again, at most a day after the cutoff
    if billing.plan_ended_held(s.account, s.id::text, p_at) then return null; end if;
    perform billing.end_sub(s.id, cut, 'unpaid', p_at, 'job', false);
    return jsonb_build_object('step', 'ended', 'reason', 'unpaid');
  end if;
  if s.period_end > p_at then return null; end if;

  inv := billing.ensure_renewal(s.id, p_at);
  if inv.status <> 'open' then return null; end if;
  if s.status = 'active' then
    due_from := s.period_end;                    -- day 0, whenever the job gets to it
    -- day 0 was tried and did not pay (no answer, a bank challenge, an answer lost): the
    -- unpaid window starts from the due date, so day 15 comes whatever happens to that try
    -- The owner's own try on the card page counts at once while it is verified (no answer,
    -- or left open), so the window never waits on a page nobody finished.
    if exists (select 1 from billing.payment_attempts
                where invoice = inv.id and created_at >= s.period_end
                  and ((channel in ('saved_card', 'none')
                        -- a written try with no answer gets a day of verifying before it counts
                        and (status in ('unknown', 'pending', 'failed') or (status = 'created' and claimed_until <= p_at - interval '1 day')))
                    or (channel = 'card_page' and status in ('created', 'unknown', 'pending', 'failed')))) then
      update billing.subscriptions set status = 'past_due', past_due_since = s.period_end, version = version + 1 where id = s.id;
      perform billing.bump(s.account);
      perform billing.log_event(s.account, p_at, 'job', 'renewal_failed', null, jsonb_build_object('invoice', inv.id), 'not paid on its day');
      return jsonb_build_object('step', 'past_due');
    end if;
  else
    due_from := s.past_due_since + make_interval(days =>
                  (select max(d) from unnest(m.retry_days) d where s.past_due_since + make_interval(days => d) <= p_at));
    if due_from is null then return null; end if;
  end if;
  -- this step tried already (only the job's own tries count: a card page the owner left
  -- open does not stop a retry), or a charge may still be taking money (verified first)
  if exists (select 1 from billing.payment_attempts
              where invoice = inv.id and status <> 'void'
                and ((channel in ('saved_card', 'none') and created_at >= due_from) or status in ('created', 'unknown'))) then
    return null;
  end if;
  -- any try on the account that may still take money (a bank challenge, an open card page,
  -- an unanswered charge, a card page on a replaced bill): nothing is charged again until it
  -- is settled or verified
  if exists (select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
              where i.account = s.account
                and ((i.status = 'open' and pa.status in ('created', 'pending', 'unknown'))
                     or (pa.channel = 'card_page' and pa.status = 'pending'))) then
    return null;
  end if;

  pm := billing.active_method(s.account);
  if pm.id is null then
    if s.status = 'active' then
      -- nothing to charge on day 0: a failed try, so the window starts
      insert into billing.payment_attempts (invoice, reference, provider, channel, amount_minor, currency, status,
                                            gateway_response, created_at, settled_at)
      values (inv.id, billing.new_reference(), 'paystack', 'none', inv.amount_minor, inv.currency, 'failed',
              'no usable card', p_at, p_at);
      update billing.subscriptions set status = 'past_due', past_due_since = s.period_end, version = version + 1 where id = s.id;
      perform billing.bump(s.account);
      perform billing.log_event(s.account, p_at, 'job', 'renewal_failed', null, jsonb_build_object('invoice', inv.id), 'no usable card');
      return jsonb_build_object('step', 'no_card');
    end if;
    return null;
  end if;
  insert into billing.payment_attempts (invoice, reference, provider, channel, payment_method, amount_minor, currency,
                                        status, claimed_until, created_at)
  values (inv.id, billing.new_reference(), 'paystack', 'saved_card', pm.id, inv.amount_minor, inv.currency,
          'created', p_at + interval '10 minutes', p_at)
  returning * into att;
  return jsonb_build_object('step', 'charge', 'charge', jsonb_build_object(
    'reference', att.reference, 'invoice', inv.id, 'amount_minor', att.amount_minor, 'currency', att.currency,
    'auth_ref', pm.auth_ref, 'auth_email', billing.charge_email(pm.auth_email, s.account)));
end $function$;
