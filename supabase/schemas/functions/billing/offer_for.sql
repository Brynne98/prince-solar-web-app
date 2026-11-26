CREATE OR REPLACE FUNCTION billing.offer_for(p_account uuid, p_at timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select o.code from billing.offers o
   where o.valid_from <= p_at and (o.valid_until is null or o.valid_until > p_at)
     and (not o.first_time_only or not exists (select 1 from billing.subscriptions s where s.account = p_account))
     and (o.max_members is null
          or (select count(*) from (
                select s.account from billing.subscriptions s where s.offer = o.code and s.account <> p_account
                union
                select i.account from billing.invoices i
                 where i.offer = o.code and i.kind = 'purchase' and i.status = 'open' and i.account <> p_account
                   and i.created_at <= p_at
                   and (i.created_at > p_at - interval '1 hour'
                        or exists (select 1 from billing.payment_attempts pa where pa.invoice = i.id
                                      and pa.status in ('created', 'pending', 'unknown')))) x
               where not exists (select 1 from billing.accounts a join private.test_users t on t.user_id = a.user_id
                                  where a.id = x.account)) < o.max_members)
   order by o.valid_from desc limit 1
$function$;
