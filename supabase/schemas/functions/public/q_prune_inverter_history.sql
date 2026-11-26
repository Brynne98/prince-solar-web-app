CREATE OR REPLACE FUNCTION public.q_prune_inverter_history(p_plant bigint, p_days integer DEFAULT 31)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  cutoff bigint := ((extract(epoch from now())::bigint - p_days * 86400) / 300) * 300;
  n integer;
begin
  perform private.history_fence();                                         -- 0277
  if private.history_deleting(p_plant) then return 0; end if;
  insert into public.inverter_history_5m
    (plant_id, sn, ts, n, ac_max, dc_max, dc_min, vac_min, vac_max, vac_last, fac_min, fac_max, gfac_min, gfac_max)
  select plant_id, sn, (ts / 300) * 300, count(*),
         max(ac_c), max(dc_c), min(dc_c), min(vac_v), max(vac_v),
         (array_agg(vac_v order by ts desc) filter (where vac_v is not null))[1],
         min(fac_hz), max(fac_hz), min(grid_fac_hz), max(grid_fac_hz)
    from public.inverter_history
   where plant_id = p_plant and ts < cutoff
   group by plant_id, sn, (ts / 300) * 300
  on conflict do nothing;

  with del as (
    delete from public.inverter_history
     where plant_id = p_plant and ts < cutoff
    returning 1)
  select count(*) into n from del;
  return n;
end $function$;
