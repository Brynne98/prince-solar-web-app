CREATE OR REPLACE FUNCTION billing.payment_reminder_put(p_account uuid, st billing.status, p_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare inv uuid; c record;
begin
  if st.plan_ends_at is null or st.plan_ends_at - p_at > interval '4 days' then return; end if;
  select id into inv from billing.invoices where subscription = st.sub and kind = 'renewal' and status = 'open'
   order by created_at desc limit 1;
  if inv is null then return; end if;
  select * into c from billing.payment_reminder_check(p_account, inv, p_at);
  if c.stop is null and c.wait is null then
    perform billing.outbox_put(p_account, 'payment_reminder', inv, null, 'payment_reminder:' || inv, p_at, null, p_at);
  end if;
end $function$;
