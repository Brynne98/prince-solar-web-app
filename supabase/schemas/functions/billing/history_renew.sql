CREATE OR REPLACE FUNCTION billing.history_renew(p_id bigint, p_claim uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  update billing.history_fetches set claimed_until = p_at + interval '90 seconds'
   where id = p_id and status = 'running' and claim = p_claim
  returning true
$function$;
