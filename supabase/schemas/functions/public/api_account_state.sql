CREATE OR REPLACE FUNCTION public.api_account_state()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  return billing.screen_state(billing.account_of(auth.uid()));
end $function$;
