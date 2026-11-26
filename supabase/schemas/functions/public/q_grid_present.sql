CREATE OR REPLACE FUNCTION public.q_grid_present(p_plant bigint, p_ts bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with voters as (
    select grid_volt_v, device_time
      from public.readings
     where plant_id = p_plant
       and ts = p_ts
       and grid_volt_v is not null
  ),
  newest as (
    -- NULL device_time cannot be dated, so it never wins. When every voter is
    -- undated -- readings from before 0031 stored device_time -- max() is NULL
    -- and the `is not distinct from` below lets them all vote, which is the old
    -- behaviour and the only thing left to do with them.
    select max(device_time) as dt from voters
  )
  select case when not exists (select 1 from voters) then null
              else (select bool_or(v.grid_volt_v > 100)
                      from voters v
                     where v.device_time
                           is not distinct from (select dt from newest)) end
$function$;
