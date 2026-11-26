CREATE OR REPLACE FUNCTION billing.begin_attempt(p_invoice uuid, p_channel text, p_at timestamp with time zone DEFAULT now(), p_account uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  inv billing.invoices;
  pm billing.payment_methods;
  att billing.payment_attempts;
  stale jsonb;
  st billing.status;
begin
  -- share lock first: pause_payments' insert then waits for every try already under way, so
  -- none is written after switch_off has looked (go-live review, Astra)
  lock table billing.payments_pause in share mode;
  if exists (select 1 from billing.payments_pause) then
    raise exception 'payments are on hold for an update' using errcode = '55000';
  end if;
  select * into inv from billing.invoices where id = p_invoice;
  if not found or inv.account is null or inv.account is distinct from coalesce(p_account, inv.account) then
    raise exception 'no such bill' using errcode = 'P0002';
  end if;
  perform billing.lock_account(inv.account);
  select * into inv from billing.invoices where id = p_invoice for update;
  if inv.status = 'paid' then raise exception 'this payment has already been made' using errcode = '22023'; end if;
  if inv.status <> 'open' then raise exception 'this payment is no longer due' using errcode = '22023'; end if;
  -- a renewal is payable while its plan runs: past due, or active on its due day before the
  -- job (pay_now, a new card). Not between the cutoff and the job, when the bill is still open.
  if inv.kind = 'renewal' then
    st := billing.account_status(inv.account, p_at);
    if st.state not in ('active', 'past_due') or st.sub is distinct from inv.subscription then
      raise exception 'this payment is no longer due' using errcode = '22023';
    end if;
    -- past the cutoff and still running: a payment on it is being checked
    if st.plan_ends_at <= p_at then raise exception 'a payment is already in progress' using errcode = '22023'; end if;
  end if;
  -- a new plan waits for a renewal paid before its plan ended (before the cached page below)
  if inv.kind = 'purchase' and (select h.in_flight from billing.renewal_hold(inv.account, p_at) h) then
    raise exception 'a payment is already in progress' using errcode = '22023';
  end if;
  if p_channel not in ('saved_card', 'card_page') then raise exception 'bad channel' using errcode = '22023'; end if;
  -- the bill's plants and the account's seats, so the delete job cannot purge them under a
  -- payment that is starting (it skips a plant held by a try: payment_hold)
  perform billing.lock_plants(coalesce(inv.plants, '{}')
                              || array(select plant from billing.seats where account = inv.account and closed_at is null));

  if p_channel = 'card_page' then
    select * into att from billing.payment_attempts
     where invoice = p_invoice and channel = 'card_page' and status = 'pending' and pay_url is not null
       and claimed_until > p_at and replaced_at is null
     order by created_at desc limit 1;
    if found then
      return jsonb_build_object('reference', att.reference, 'invoice', inv.id, 'kind', inv.kind,
                                'amount_minor', att.amount_minor, 'currency', att.currency, 'url', att.pay_url);
    end if;
  end if;

  -- any open bill of the account: a try there may still take money
  select jsonb_agg(pa.reference order by pa.created_at) into stale
    from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
   where i.account = inv.account and i.status = 'open' and pa.status in ('created', 'pending', 'unknown')
     and pa.claimed_until <= p_at;
  if stale is not null then return jsonb_build_object('verify', stale); end if;
  if billing.payment_in_flight(inv.account) then return jsonb_build_object('busy', true); end if;

  if p_channel = 'saved_card' then
    pm := billing.active_method(inv.account);
    if pm.id is null then raise exception 'no saved card' using errcode = 'P0002'; end if;
    -- an open card page can still take money, on any bill (a replaced bill's page too):
    -- Paystack is asked first, and while it may still settle nothing is charged (the caller
    -- gets {verify} again and says a payment is under way)
    select jsonb_agg(pa.reference order by pa.created_at) into stale
      from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
     where i.account = inv.account and pa.channel = 'card_page' and pa.status = 'pending';
    if stale is not null then return jsonb_build_object('verify', stale); end if;
  end if;
  perform billing.replace_card_pages(array[p_invoice], p_at);
  insert into billing.payment_attempts (invoice, reference, provider, channel, payment_method, amount_minor, currency,
                                        status, claimed_until, created_at)
  values (p_invoice, billing.new_reference(), 'paystack', p_channel, pm.id, inv.amount_minor, inv.currency,
          case p_channel when 'saved_card' then 'created' else 'pending' end,
          p_at + case p_channel when 'saved_card' then interval '10 minutes' else interval '1 hour' end, p_at)
  returning * into att;
  return jsonb_build_object('reference', att.reference, 'invoice', inv.id, 'kind', inv.kind,
                            'amount_minor', att.amount_minor, 'currency', att.currency,
                            'auth_ref', pm.auth_ref,
                            'auth_email', case when pm.id is not null then billing.charge_email(pm.auth_email, inv.account) end);
end $function$;
