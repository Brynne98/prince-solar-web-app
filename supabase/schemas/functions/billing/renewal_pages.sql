CREATE OR REPLACE FUNCTION billing.renewal_pages(p_account uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(pa.reference order by pa.created_at), '[]'::jsonb)
    from billing.payment_attempts pa
   where pa.invoice = (select h.bill from billing.renewal_hold(p_account, p_at) h)
     and pa.channel = 'card_page' and pa.status in ('created', 'pending', 'unknown')
$function$;
