CREATE OR REPLACE FUNCTION billing.payment_hold(p_plant bigint, p_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select exists (
    select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
     where pa.status in ('created', 'pending', 'unknown')
       and pa.created_at <= p_at and pa.created_at > p_at - interval '24 hours'
       and (p_plant = any (i.plants)
            or exists (select 1 from billing.seats s where s.account = i.account and s.plant = p_plant
                          and s.closed_at is null)))
$function$;
