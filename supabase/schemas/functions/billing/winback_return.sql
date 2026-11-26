CREATE OR REPLACE FUNCTION billing.winback_return(p_reference text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select jsonb_build_object('user', a.user_id, 'email_id', q.id, 'days', pa.settled_at::date - q.sent_at::date,
                            'at', pa.settled_at)
    from billing.payment_attempts pa
    join billing.invoices i on i.id = pa.invoice and i.kind = 'purchase'
    join billing.accounts a on a.id = i.account
    cross join lateral (select e.id, e.sent_at from public.email_queue e
                         where e.user_id = a.user_id and e.kind = 'winback' and e.status = 'sent'
                           and e.sent_at < pa.created_at
                         order by e.sent_at desc limit 1) q
   where pa.reference = p_reference and pa.status = 'success'
$function$;
