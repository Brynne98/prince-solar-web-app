CREATE OR REPLACE FUNCTION billing.record_dispute(p_reference text, p_event text, p_status text, p_lost boolean, p_amount integer, p_at timestamp with time zone DEFAULT now(), p_dispute_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  att billing.payment_attempts;
  inv billing.invoices;
  o billing.old_references;
  resolve boolean := p_event = 'charge.dispute.resolve';
begin
  select * into att from billing.payment_attempts where reference = p_reference;
  if not found then
    -- an old paid charge kept only as a reference (copy_from_old, past 120 days): its bill and
    -- try come back from the copied record, so an open dispute blocks a delete and a lost one
    -- is owed. No plan link: the period it paid for is long over.
    select * into o from billing.old_references where reference = p_reference and status = 'paid' and account is not null
       and kind is not null and amount_minor is not null and (kind = 'card_check' or plan is not null);
    if not found then return jsonb_build_object('action', 'ignored'); end if;
    perform billing.lock_account(o.account);
    select * into att from billing.payment_attempts where reference = p_reference;
    if not found then
      insert into billing.invoices (account, kind, status, plan, interval, amount_minor, currency, created_at, paid_at)
      values (o.account, o.kind, 'paid', o.plan, o.interval, o.amount_minor, 'ZAR', o.settled_at, o.settled_at)
      returning id into inv.id;
      insert into billing.payment_attempts (invoice, reference, provider, channel, amount_minor, currency, status,
                                            gateway_response, created_at, settled_at)
      values (inv.id, p_reference, 'paystack', coalesce(o.channel, 'card_page'), o.amount_minor, 'ZAR', 'success',
              'copied: paid before the switch-over (restored for a dispute)', o.settled_at, o.settled_at)
      returning * into att;
    end if;
  end if;
  select * into inv from billing.invoices where id = att.invoice;
  if inv.account is not null then perform billing.lock_account(inv.account); end if;
  select * into inv from billing.invoices where id = att.invoice;
  select * into att from billing.payment_attempts where id = att.id for update;
  -- final per dispute: the same dispute again changes nothing; a new dispute (another id) on
  -- the same payment is its own
  if att.dispute_resolved_at is not null and (p_dispute_id is null or p_dispute_id is not distinct from att.dispute_id) then
    return jsonb_build_object('action', 'again', 'status', att.dispute_status);
  end if;
  update billing.payment_attempts
     set dispute_status = coalesce(p_status, p_event), dispute_id = coalesce(p_dispute_id, dispute_id),
         dispute_open = not resolve, dispute_resolved_at = case when resolve then p_at end
   where id = att.id
  returning * into att;
  if inv.account is not null then
    perform billing.log_event(inv.account, p_at, 'paystack', 'dispute', null,
                              jsonb_build_object('reference', p_reference, 'dispute', p_dispute_id, 'event', p_event,
                                                 'status', p_status, 'lost', p_lost));
  end if;
  if not (resolve and coalesce(p_lost, false)) then return jsonb_build_object('action', 'recorded'); end if;
  return billing.money_back(att, inv, p_amount, 'dispute_lost', p_at);
end $function$;
