CREATE OR REPLACE FUNCTION public.battery_banks_detect(p_plant bigint, p_dry boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  cur      text;
  n_pairs  bigint;
  p_close  double precision;
  p_apart  double precision;
  detected text;
begin
  select battery_banks into cur from public.plant_config where plant_id = p_plant;

  with r as (
    select ts, sn, batt_soc as soc, batt_voltage_v as v
      from public.readings
     where plant_id = p_plant
       and ts > extract(epoch from now())::bigint - 86400
       and not carried
       and batt_soc between 1 and 100
  ),
  p as (
    select abs(a.soc - b.soc) as ds, abs(a.v - b.v) as dv
      from r a join r b on a.ts = b.ts and a.sn < b.sn
  )
  select count(*),
         avg((ds <= 2 and coalesce(dv, 0) <= 1)::int),
         avg((ds > 5)::int)
    into n_pairs, p_close, p_apart
    from p;

  if n_pairs < 60 then
    return jsonb_build_object('plant', p_plant, 'pairs', n_pairs, 'decided', false);
  end if;
  if p_close >= 0.95 then detected := 'shared';
  elsif p_apart >= 0.20 then detected := 'per-inverter';
  else
    return jsonb_build_object('plant', p_plant, 'pairs', n_pairs, 'close', round(p_close::numeric, 3),
                              'apart', round(p_apart::numeric, 3), 'decided', false, 'reason', 'unclear');
  end if;

  if not p_dry and detected is distinct from cur then
    update public.plant_config set battery_banks = detected where plant_id = p_plant;
  end if;

  return jsonb_build_object('plant', p_plant, 'detected', detected, 'was', cur, 'pairs', n_pairs,
                            'close', round(p_close::numeric, 3), 'apart', round(p_apart::numeric, 3),
                            'decided', true, 'dry', p_dry);
end $function$;
