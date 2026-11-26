CREATE OR REPLACE FUNCTION billing.event_done(p_id bigint, p_error text DEFAULT NULL::text, p_at timestamp with time zone DEFAULT now())
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  update billing.payment_events set processed_at = case when p_error is null then p_at end, last_error = p_error
   where id = p_id
$function$;
