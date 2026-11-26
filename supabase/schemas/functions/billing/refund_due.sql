CREATE OR REPLACE FUNCTION billing.refund_due(p_attempt uuid, p_reference text, p_account uuid, p_currency text, p_reason text, p_at timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare rid uuid;
begin
  insert into billing.refunds (attempt, reference, account, currency, reason, status, created_at, updated_at)
  values (p_attempt, p_reference, p_account, p_currency, p_reason, 'due', p_at, p_at)
  on conflict (reference) where reason <> 'manual' do nothing
  returning refunds.id into rid;
  if rid is null then select r.id into rid from billing.refunds r where r.reference = p_reference and r.reason <> 'manual'; end if;
  return rid;
end $function$;
