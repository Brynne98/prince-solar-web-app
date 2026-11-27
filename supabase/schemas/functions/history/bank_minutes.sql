CREATE OR REPLACE FUNCTION history.bank_minutes(p_id bigint, p_claim uuid, p_rows jsonb, p_source text, p_at timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pl bigint := history.held('day', p_id, p_claim, p_at); n int;
begin
  perform set_config('billing.guarded', 'on', true);
  n := public.q_insert_recovered(pl, p_rows, p_source);
  perform set_config('billing.guarded', 'off', true);
  return n;
end $function$;
