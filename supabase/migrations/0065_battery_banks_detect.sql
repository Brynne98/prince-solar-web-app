-- ============================================================================
-- 0065 — battery_banks is worked out from the readings, not asked. (SOLAR-31)
--
-- plant_config.battery_banks ('shared' | 'per-inverter', 0042) was a Settings
-- question most owners cannot answer: to them the system is one unit. Both
-- plants answered it wrongly ('per-inverter') while every inverter on each read
-- the same pack: over 24 h on 2026-10-03, 100% of paired minutes agreed within
-- 1% charge, and voltage within 1.3 V (495944, 3 inverters, 4,320 pairs) and
-- 0.7 V (538820, 2 inverters, 240 pairs).
--
-- Inverters on one pack read one BMS, so their charge and voltage move together;
-- separate packs drift apart. A pair is two inverters' real (not carried) rows at
-- the same minute. Shared: at least 60 pairs, 95% within 2% charge and 1 V.
-- Separate: 20% of pairs more than 5% charge apart. Anything between leaves the
-- stored value alone, as does a plant with fewer than two battery inverters.
--
-- No source column: the Settings question goes away in the same change, so
-- there is no owner answer to protect. p_dry reports without writing.
-- ============================================================================

create or replace function public.battery_banks_detect(p_plant bigint, p_dry boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
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
end $$;
revoke all on function public.battery_banks_detect(bigint, boolean) from public, anon, authenticated;
grant execute on function public.battery_banks_detect(bigint, boolean) to service_role;
