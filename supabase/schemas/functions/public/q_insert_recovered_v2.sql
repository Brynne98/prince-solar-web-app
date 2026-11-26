CREATE OR REPLACE FUNCTION public.q_insert_recovered_v2(p_plant bigint, p_version bigint, p_rows jsonb, p_source text DEFAULT 'plantfeed'::text, p_at timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
declare n integer;
begin
  perform billing.guard_write(p_plant, p_version, p_at);
  perform set_config('billing.guarded', 'on', true);
  n := public.q_insert_recovered(p_plant, p_rows, p_source);
  perform set_config('billing.guarded', 'off', true);
  return n;
end $function$;
