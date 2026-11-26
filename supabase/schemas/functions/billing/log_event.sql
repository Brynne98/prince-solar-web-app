CREATE OR REPLACE FUNCTION billing.log_event(p_account uuid, p_at timestamp with time zone, p_actor text, p_kind text, p_before jsonb, p_after jsonb, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  insert into billing.account_events (account, at, actor, kind, before, after, reason)
  values (p_account, p_at, p_actor, p_kind, p_before, p_after, p_reason)
$function$;
