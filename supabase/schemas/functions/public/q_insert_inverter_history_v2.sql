CREATE OR REPLACE FUNCTION public.q_insert_inverter_history_v2(p_plant bigint, p_version bigint, p_sn text, p_rows jsonb, p_at timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
declare n integer;
begin
  perform billing.guard_write(p_plant, p_version, p_at);
  perform set_config('billing.guarded', 'on', true);
  n := public.q_insert_inverter_history(p_plant, p_sn, p_rows);
  perform set_config('billing.guarded', 'off', true);
  return n;
end $function$;
