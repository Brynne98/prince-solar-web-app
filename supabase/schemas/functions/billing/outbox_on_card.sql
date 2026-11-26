CREATE OR REPLACE FUNCTION billing.outbox_on_card()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare at timestamptz := coalesce(new.activated_at, new.created_at);
begin
  if new.active and (tg_op = 'INSERT' or not old.active) and new.account is not null
     and exists (select 1 from billing.payment_methods pm where pm.account = new.account and pm.id <> new.id) then
    perform billing.outbox_put(new.account, 'card_changed', null, new.id::text,
                               'card_changed:' || new.id || ':' || extract(epoch from at)::bigint,
                               at, at + interval '2 days', at);
  end if;
  return null;
end $function$;
