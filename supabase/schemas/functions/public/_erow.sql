CREATE OR REPLACE FUNCTION public._erow(r plant_energy)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  select public._energy_row(r.bucket, r.period, r.pv_kwh, r.load_kwh, r.imp_kwh,
                            r.exp_kwh, r.chg_kwh, r.dischg_kwh)
$function$;
