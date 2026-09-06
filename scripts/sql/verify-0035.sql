-- verify-0035: recover from per-inverter history (0034), checked on one real gap.
-- Before running: the dry run (recover?dry=1&plant=&day=) must have shown median
-- error < 150 W per series and < 2 SoC; then delete the gap's plantfeed row (if the
-- old recover already filled it) and run recover once. Set target_ts / target_plant.
--   scripts/verify.sh scripts/sql/verify-0035.sql check <snapshot-file>
do $$
declare
  target_plant bigint := 538820;
  target_ts    bigint := 1788620400;   -- 2026-09-05 15:00 UTC, lost in the 0032 deploy window
  src text; r record; n record; bad text := ''; rec_n bigint; est boolean; day date; report text;
begin
  select source, pv_w, load_w, batt_w, grid_w, soc into r
    from public.agg_minute where plant_id = target_plant and ts = target_ts;
  src := r.source;

  -- neighbours: the poller minutes within 2 minutes either side
  select avg(pv_w) as pv, avg(load_w) as load, avg(batt_w) as batt, avg(grid_w) as grid, avg(soc) as soc, count(*) as c
    into n
    from public.agg_minute
   where plant_id = target_plant and source = 'poller'
     and ts between target_ts - 120 and target_ts + 120 and ts <> target_ts;

  if src is distinct from 'invhistory' then bad := bad || ' source=' || coalesce(src, 'none'); end if;
  if n.c < 2 then bad := bad || ' neighbours=' || n.c; end if;
  if abs(r.pv_w - n.pv)     > greatest(150, 0.15 * abs(n.pv))     then bad := bad || format(' pv=%s~%s', r.pv_w, round(n.pv)); end if;
  if abs(r.load_w - n.load) > greatest(150, 0.15 * abs(n.load))   then bad := bad || format(' load=%s~%s', r.load_w, round(n.load)); end if;
  if abs(r.grid_w - n.grid) > greatest(150, 0.15 * abs(n.grid))   then bad := bad || format(' grid=%s~%s', r.grid_w, round(n.grid)); end if;
  if abs(r.batt_w - n.batt) > greatest(150, 0.15 * abs(n.batt))   then bad := bad || format(' batt=%s~%s', r.batt_w, round(n.batt)); end if;
  if abs(r.soc - n.soc) > 2 then bad := bad || format(' soc=%s~%s', r.soc, round(n.soc)); end if;

  -- it counts as recovered (q_recovered_minutes) and its 5-minute bucket counts it
  -- as a feed row (q_day_agg.feed_n, which api_history turns into `est` once a
  -- whole bucket is recovered)
  day := (to_timestamp(target_ts) at time zone public.plant_tz(target_plant))::date;
  rec_n := public.q_recovered_minutes(target_plant, day);
  select (a.feed_n >= 1) into est
    from public.q_day_agg(target_plant, day, null) a
   where a.hm = to_char(date_trunc('minute', to_timestamp(target_ts) at time zone public.plant_tz(target_plant))
                        - make_interval(mins => extract(minute from to_timestamp(target_ts) at time zone public.plant_tz(target_plant))::int % 5), 'HH24:MI');
  if rec_n < 1 then bad := bad || ' recovered_minutes=' || rec_n; end if;
  if est is not true then bad := bad || ' bucket_feed_n=' || coalesce(est::text, 'null'); end if;

  report := format('plant=%s ts=%s source=%s row=(pv %s, load %s, batt %s, grid %s, soc %s) neighbours=(pv %s, load %s, batt %s, grid %s, soc %s, n %s) recovered_minutes=%s bucket_counted=%s',
    target_plant, target_ts, src, r.pv_w, r.load_w, r.batt_w, r.grid_w, r.soc,
    round(n.pv), round(n.load), round(n.batt), round(n.grid), round(n.soc), n.c, rec_n, est);
  raise notice '%', report;
  create temp table if not exists _verify_report (report text); delete from _verify_report;
  insert into _verify_report values (report);
  if bad <> '' then raise exception 'FAIL%: %', bad, report; end if;
  update _verify_report v set report = 'verify_0035: PASS | ' || v.report;
end $$;
select report from _verify_report;
