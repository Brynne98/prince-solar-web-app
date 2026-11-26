CREATE OR REPLACE FUNCTION billing.outbox_on_attempt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare inv billing.invoices;
begin
  if new.status = 'failed' and (tg_op = 'INSERT' or old.status is distinct from 'failed')
     and coalesce(new.gateway_response, '') not like 'copied: %' and not new.hard_decline
     -- the owner's own card page shows its result on screen: no email (0248)
     and new.channel in ('saved_card', 'none') then
    select * into inv from billing.invoices where id = new.invoice;
    if inv.kind = 'renewal' and new.channel = 'none' then
      -- no card to charge on the due date: the payment is due, not failed
      perform billing.outbox_put(inv.account, 'payment_due', inv.id, new.id::text, 'payment_due:' || inv.id,
                                 coalesce(new.settled_at, new.created_at), null, coalesce(new.settled_at, new.created_at));
    elsif inv.kind = 'renewal' then
      perform billing.outbox_put(inv.account, 'payment_failed', inv.id, new.id::text, 'payment_failed:' || new.id,
                                 coalesce(new.settled_at, new.created_at), null, coalesce(new.settled_at, new.created_at));
    end if;
  end if;
  return null;
end $function$;
