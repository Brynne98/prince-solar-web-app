CREATE OR REPLACE FUNCTION private.billing_refund_reason(p_error text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when p_error like 'refund failed: %' then
           case when position(' | ' in p_error) > 0 then substr(p_error, position(' | ' in p_error) + 3) end
         else p_error end
$function$;
