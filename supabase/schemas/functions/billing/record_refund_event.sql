CREATE OR REPLACE FUNCTION billing.record_refund_event(p_reference text, p_status text, p_provider_id text, p_amount integer, p_reason text, p_at timestamp with time zone DEFAULT now(), p_provider_ref text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  st text := case lower(p_status) when 'processed' then 'processed' when 'failed' then 'failed'
                                  when 'needs-attention' then 'failed' else 'pending' end;
  r billing.refunds;
  att billing.payment_attempts;
  acc uuid;
begin
  -- events arrive out of order: processed is final, and a late pending does not undo failed
  update billing.refunds
     set status = case when status = 'processed' or (st = 'pending' and status = 'failed') then status else st end,
         provider_refund_id = coalesce(provider_refund_id, p_provider_id, p_provider_ref),
         amount_minor = coalesce(amount_minor, p_amount),
         last_error = case when st = 'failed' and status <> 'processed' then p_reason else last_error end,
         next_try_at = case when status = 'processed' then null
                            when st = 'failed' and reason <> 'manual' then p_at
                            when st = 'pending' and status = 'failed' then next_try_at else null end,
         updated_at = p_at
   where (p_provider_id is not null and provider_refund_id = p_provider_id)
      or (p_provider_id is null and p_provider_ref is not null and provider_refund_id = p_provider_ref)
      or (reference = p_reference and reason <> 'manual' and (provider_refund_id is null or p_provider_id is null))
  returning * into r;
  if found then return to_jsonb(r); end if;
  select * into att from billing.payment_attempts where reference = p_reference;
  select i.account into acc from billing.invoices i where i.id = att.invoice;
  insert into billing.refunds (attempt, reference, account, amount_minor, currency, reason, status, last_error,
                               provider_refund_id, created_at, updated_at)
  values (att.id, p_reference, acc, p_amount, att.currency, 'manual', st, case when st = 'failed' then p_reason end,
          coalesce(p_provider_id, p_provider_ref), p_at, p_at)
  returning * into r;
  return to_jsonb(r);
end $function$;
