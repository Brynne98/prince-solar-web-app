CREATE OR REPLACE FUNCTION billing.replace_card_pages(p_invoices uuid[], p_at timestamp with time zone)
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  update billing.payment_attempts set replaced_at = p_at, claimed_until = least(claimed_until, p_at)
   where invoice = any (p_invoices) and channel = 'card_page' and status = 'pending' and replaced_at is null
$function$;
