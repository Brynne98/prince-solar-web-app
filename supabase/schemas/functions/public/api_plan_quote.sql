CREATE OR REPLACE FUNCTION public.api_plan_quote(p_plan text, p_interval text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare acc uuid := billing.account_of(auth.uid(), false);
begin
  if acc is null then raise exception 'sign in first' using errcode = '42501'; end if;
  return billing.quote(acc, p_plan, p_interval);
end $function$;
