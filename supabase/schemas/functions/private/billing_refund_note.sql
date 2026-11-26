CREATE OR REPLACE FUNCTION private.billing_refund_note(p_error text, p_why text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select left('refund failed: ' || p_why || coalesce(' | ' || private.billing_refund_reason(p_error), ''), 300)
$function$;
