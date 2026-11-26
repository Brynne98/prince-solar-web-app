CREATE OR REPLACE FUNCTION private.agg_minute_rollup(p_days integer DEFAULT 61)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  cutoff bigint := ((extract(epoch from now())::bigint - p_days * 86400) / 300) * 300;
  made bigint; gone bigint;
begin
  perform private.history_fence();                                         -- 0277
  insert into public.agg_5m
    (plant_id, ts, n, n_poller,
     pv_w_avg, pv_w_min, pv_w_max, load_w_avg, load_w_min, load_w_max,
     batt_w_avg, batt_w_min, batt_w_max, grid_w_avg, grid_w_min, grid_w_max,
     soc_avg, soc_min, soc_max, grid_in_w_avg, grid_out_w_avg, batt_pos_w_avg, batt_neg_w_avg)
  select plant_id, (ts / 300) * 300, count(*),
         count(*) filter (where coalesce(source, 'poller') = 'poller'),
         avg(pv_w), min(pv_w), max(pv_w), avg(load_w), min(load_w), max(load_w),
         avg(batt_w), min(batt_w), max(batt_w), avg(grid_w), min(grid_w), max(grid_w),
         avg(soc), min(soc), max(soc),
         avg(greatest(grid_w, 0)), avg(greatest(-grid_w, 0)),
         avg(greatest(batt_w, 0)), avg(greatest(-batt_w, 0))
    from public.agg_minute
   where ts < cutoff and plant_id is not null
     and plant_id not in (select q.plant_id from private.history_delete_queue q)   -- 0277
   group by plant_id, (ts / 300) * 300
  on conflict do nothing;
  get diagnostics made = row_count;

  delete from public.agg_minute where ts < cutoff and plant_id is not null;
  get diagnostics gone = row_count;
  return jsonb_build_object('buckets', made, 'minutes', gone);
end $function$;
