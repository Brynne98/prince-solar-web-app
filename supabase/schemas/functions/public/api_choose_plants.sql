CREATE OR REPLACE FUNCTION public.api_choose_plants(p_plants bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare acc uuid := billing.account_of(auth.uid());
begin
  perform billing.set_chosen_plants(acc, p_plants);
  return billing.screen_state(acc);
end $function$;
