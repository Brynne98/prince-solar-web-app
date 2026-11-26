CREATE OR REPLACE FUNCTION billing.outbox_on_invoice()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  if new.status = 'paid' and old.status is distinct from 'paid' and new.kind in ('purchase', 'renewal', 'upgrade')
     and new.amount_minor > 0 then
    perform billing.outbox_put(new.account, 'receipt', new.id, null, 'receipt:' || new.id, new.paid_at, null, new.paid_at);
  end if;
  return null;
end $function$;
