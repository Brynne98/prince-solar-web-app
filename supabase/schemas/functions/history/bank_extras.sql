CREATE OR REPLACE FUNCTION history.bank_extras(p_step text, p_id bigint, p_claim uuid, p_sn text, p_rows jsonb, p_at timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '1s'
 SET statement_timeout TO '10s'
AS $function$
declare pl bigint := history.held(p_step, p_id, p_claim, p_at); n int;
begin
  perform set_config('billing.guarded', 'on', true);
  n := public.q_insert_inverter_history(pl, p_sn, p_rows);
  perform set_config('billing.guarded', 'off', true);
  return n;
end $function$;
