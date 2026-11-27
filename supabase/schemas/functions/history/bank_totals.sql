CREATE OR REPLACE FUNCTION history.bank_totals(p_id bigint, p_claim uuid, p_rows jsonb, p_at timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '1s'
 SET statement_timeout TO '10s'
AS $function$
declare pl bigint := history.held('totals', p_id, p_claim, p_at); v bigint;
begin
  v := (select t.version from history.totals t where t.plant = p_id);
  return public.q_upsert_plant_energy_v2(pl, v, p_rows, p_at);
end $function$;
