CREATE OR REPLACE FUNCTION public.api_plant_days(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  -- plant and day bounds as variables: planned with fixed values, the
  -- (plant_id, ts) keys are used rather than a walk of the ts index
  v_plant bigint := public.my_plant(p_plant);
  v_tz    text   := public.plant_tz(v_plant);
  v_today date   := public.today_tz(v_tz);
  v_lo    bigint := public.day_start_epoch_tz(v_today - 60, v_tz);
  v_days  bigint;
begin
  if exists (select 1 from public.agg_minute where plant_id = v_plant and ts < v_lo)
     or exists (select 1 from public.agg_5m where plant_id = v_plant and ts < v_lo) then
    return jsonb_build_object('days', 61);
  end if;
  select count(*) into v_days
    from generate_series(0, 60) g(i)
   where exists (select 1 from public.agg_minute a
                  where a.plant_id = v_plant
                    and a.ts >= public.day_start_epoch_tz(v_today - g.i, v_tz)
                    and a.ts <  public.day_start_epoch_tz(v_today - g.i, v_tz) + 86400)
      or exists (select 1 from public.agg_5m f
                  where f.plant_id = v_plant
                    and f.ts >= public.day_start_epoch_tz(v_today - g.i, v_tz)
                    and f.ts <  public.day_start_epoch_tz(v_today - g.i, v_tz) + 86400);
  return jsonb_build_object('days', v_days);
end $function$;
