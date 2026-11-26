CREATE OR REPLACE FUNCTION billing.verify_unanswered(p_reference text, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare att billing.payment_attempts; inv billing.invoices;
begin
  -- on hold for the way back (billing.pause_payments): no try changes, as in apply_payment
  lock table billing.payments_pause in share mode;
  if exists (select 1 from billing.payments_pause) then
    raise exception 'payments are on hold for an update' using errcode = '55000';
  end if;
  select * into att from billing.payment_attempts where reference = p_reference;
  if not found then return jsonb_build_object('action', 'ignored'); end if;
  select * into inv from billing.invoices where id = att.invoice;
  if inv.account is not null then perform billing.lock_account(inv.account); end if;
  select * into att from billing.payment_attempts where id = att.id for update;
  if att.status not in ('created', 'pending', 'unknown') or att.channel <> 'card_page' or inv.kind <> 'renewal' then
    return jsonb_build_object('action', 'unanswered');
  end if;
  if p_at >= billing.sub_cutoff(inv.subscription) + interval '24 hours' then
    update billing.payment_attempts
       set status = 'failed', gateway_response = 'timeout: no final answer 24 hours after the plan ended',
           settled_at = p_at, claimed_until = null, verified_processing = false, verify_unanswered_at = null
     where id = att.id;
    return jsonb_build_object('action', 'failed', 'kind', inv.kind, 'declined', false, 'hard', false);
  end if;
  update billing.payment_attempts set verify_unanswered_at = coalesce(verify_unanswered_at, p_at) where id = att.id;
  return jsonb_build_object('action', 'unanswered');
end $function$;
