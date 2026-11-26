CREATE OR REPLACE FUNCTION public.q_upsert_plant_energy_v2(p_plant bigint, p_version bigint, p_rows jsonb, p_at timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare n integer;
begin
  perform billing.guard_write(p_plant, p_version, p_at);
  perform set_config('billing.guarded', 'on', true);       -- checked above: plant_row_guard lets it through
  insert into public.plant_energy (plant_id, bucket, period, pv_kwh, load_kwh, imp_kwh, exp_kwh, chg_kwh, dischg_kwh, synced_at)
  select p_plant, r.bucket, r.period, r.pv_kwh, r.load_kwh, r.imp_kwh, r.exp_kwh, r.chg_kwh, r.dischg_kwh, r.synced_at
    from jsonb_to_recordset(p_rows) r (bucket text, period date, pv_kwh numeric, load_kwh numeric, imp_kwh numeric,
                                       exp_kwh numeric, chg_kwh numeric, dischg_kwh numeric, synced_at timestamptz)
  on conflict (plant_id, bucket, period) do update
     set pv_kwh = excluded.pv_kwh, load_kwh = excluded.load_kwh, imp_kwh = excluded.imp_kwh, exp_kwh = excluded.exp_kwh,
         chg_kwh = excluded.chg_kwh, dischg_kwh = excluded.dischg_kwh, synced_at = excluded.synced_at;
  get diagnostics n = row_count;
  perform set_config('billing.guarded', 'off', true);
  return n;
end $function$;
