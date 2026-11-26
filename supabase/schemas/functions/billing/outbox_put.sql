CREATE OR REPLACE FUNCTION billing.outbox_put(p_account uuid, p_key text, p_invoice uuid, p_ref text, p_dedupe text, p_not_before timestamp with time zone, p_expires timestamp with time zone, p_at timestamp with time zone)
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  insert into billing.outbox (account, key, invoice, ref, dedupe_key, not_before, expires_at, created_at)
  select p_account, p_key, p_invoice, p_ref, p_dedupe, p_not_before, p_expires, p_at where p_account is not null
  on conflict (dedupe_key) do nothing
$function$;
