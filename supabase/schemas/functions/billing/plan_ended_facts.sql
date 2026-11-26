CREATE OR REPLACE FUNCTION billing.plan_ended_facts(o billing.outbox)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'ended_at', coalesce(o.ended_at, s.ended_at),
    'reason', (select e.reason from billing.account_events e
                where e.account = o.account and e.kind = 'plan_ended' and e.after->>'sub' = o.ref
                  and (o.ended_at is null or (e.after->>'ended_at')::timestamptz = o.ended_at)
                order by e.at desc, e.id desc limit 1),
    'paid_unknown', exists (select 1 from billing.payment_attempts pa
                             where pa.invoice = (select i.id from billing.invoices i where i.subscription = s.id
                                                    and i.kind = 'renewal' order by i.created_at desc limit 1)
                               and pa.channel = 'card_page' and pa.created_at < coalesce(o.ended_at, s.ended_at)
                               and (pa.status in ('created', 'pending', 'unknown')
                                    or (pa.status = 'failed' and pa.gateway_response like 'timeout: %'))))
    from billing.subscriptions s where s.id::text = o.ref
$function$;
