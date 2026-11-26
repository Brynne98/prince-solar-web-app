CREATE OR REPLACE FUNCTION billing.invoice_out(p_inv billing.invoices)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select jsonb_build_object('invoice', p_inv.id, 'kind', p_inv.kind, 'status', p_inv.status,
                            'amount_minor', p_inv.amount_minor, 'currency', p_inv.currency,
                            'saved_card', p_inv.account is not null and exists
                              (select 1 from billing.payment_methods pm where pm.account = p_inv.account and pm.active))
$function$;
