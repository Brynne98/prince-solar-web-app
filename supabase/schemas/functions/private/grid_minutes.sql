CREATE OR REPLACE FUNCTION private.grid_minutes(p_plant bigint, p_from bigint, p_to bigint)
 RETURNS TABLE(ts bigint, present boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with voters as (
    select r.ts, r.grid_volt_v, r.device_time
      from public.readings r
     where r.plant_id = p_plant
       and r.ts >= p_from and r.ts < p_to
       and r.grid_volt_v is not null
       and (r.grid_volt_v <> 0 or r.device_time is not null)
  ),
  newest as (
    select v.ts, max(v.device_time) as dt from voters v group by v.ts
  ),
  ours as (
    select v.ts, bool_or(v.grid_volt_v > 100) as present
      from voters v join newest n on n.ts = v.ts
     where v.device_time is not distinct from n.dt
     group by v.ts
  ),
  -- 0167: SunSynk's history for the minutes we have no reading for
  hist as (
    select (h.ts / 60) * 60 as ts, bool_or(h.grid_fac_hz >= 40) as present
      from public.inverter_history h
     where h.plant_id = p_plant
       and h.ts >= p_from and h.ts < p_to
       and h.grid_fac_hz is not null
       and coalesce((select c.has_grid from plants.settings c where c.plant_id = p_plant), true)
     group by 1
  )
  select o.ts, o.present from ours o
  union all
  select h.ts, h.present from hist h where not exists (select 1 from ours o where o.ts = h.ts)
$function$;
