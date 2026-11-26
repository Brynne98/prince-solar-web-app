CREATE OR REPLACE FUNCTION billing.outbox_on_refund()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  if new.status = 'processed' and (tg_op = 'INSERT' or old.status is distinct from 'processed')
     and new.reason not in ('card_check', 'reversed', 'unknown_account') then
    perform billing.outbox_put(new.account, 'refund', null, new.id::text, 'refund:' || new.id, new.updated_at, null, new.updated_at);
  end if;
  return null;
end $function$;
