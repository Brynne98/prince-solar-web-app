CREATE OR REPLACE FUNCTION billing.payment_in_flight(p_account uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select exists (select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
                  where i.account = p_account and i.status = 'open' and pa.status in ('created', 'pending', 'unknown')
                    and not (pa.channel = 'card_page' and pa.status = 'pending'))
$function$;
