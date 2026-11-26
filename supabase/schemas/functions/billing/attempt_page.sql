CREATE OR REPLACE FUNCTION billing.attempt_page(p_reference text, p_url text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  update billing.payment_attempts set pay_url = p_url
   where reference = p_reference and channel = 'card_page' and status = 'pending' and p_url like 'https://%'
  returning jsonb_build_object('reference', reference)
$function$;
