-- verify-0033: endpoint tiering, checked over the last 30 logged minutes.
-- Run >= 30 minutes after deploying 0033 + poll:
--   scripts/verify.sh scripts/sql/verify-0033.sql check <snapshot-file>
-- Raises on the first failed criterion. Supersedes verify-0032 (call budget changed).
do $$
declare
  win_from bigint; win_to bigint;
  n_ts int; n_ts_gap int; n_inv_short int; n_agg_short int; n_gaps int;
  c_bad_dt int; c_missed int; v_mismatch int;
  t_load_missed int; t_load_extra int; t_out_missed int; t_out_extra int; t_null_ts int;
  d_fetched int; d_fetched_ok int; d_derived int; d_derived_bad int;
  n_resp int; n_bad_calls int; avg_calls numeric;
  stale text; n_plants int; n_bad_acc int;
  report text;
begin
  select min(ts), max(ts) into win_from, win_to
    from (select distinct ts from public.readings order by ts desc limit 30) w;

  -- 1. every row lands
  with w as (select distinct ts from public.readings where ts between win_from and win_to)
  select count(*), count(*) filter (where prev is not null and ts - prev <> 60) into n_ts, n_ts_gap
    from (select ts, lag(ts) over (order by ts) as prev from w) x;
  with per as (select sn, count(distinct ts) as n from public.readings where ts between win_from and win_to group by sn)
  select count(*) filter (where n <> 30) into n_inv_short from per;
  with per as (select plant_id, count(distinct ts) as n from public.agg_minute where ts between win_from and win_to group by plant_id)
  select count(*) filter (where n <> 30) into n_agg_short from per;
  select count(*) into n_gaps from private.gaps where to_ts >= win_from;

  with r as (
    select r.*, to_jsonb(r) as j,
           lag(to_jsonb(r)) over (partition by sn order by ts) as pj,
           lag(device_time) over (partition by sn order by ts) as prev_dt,
           lag(load_w) over (partition by sn order by ts) as prev_load_w,
           lag(load_fetched_ts) over (partition by sn order by ts) as prev_lft,
           lag(output_fetched_ts) over (partition by sn order by ts) as prev_oft,
           (lag(grid_relay_status) over (partition by sn order by ts) = '0'
             or lag(grid_volt_v) over (partition by sn order by ts) < 100) as prev_outage,
           (grid_relay_status = '0' or grid_volt_v < 100) as this_outage,
           (ts / 60) % 10 = 0 as refresh_min
      from public.readings r
     where r.ts between win_from - 11 * 60 and win_to),
    w as (select * from r where ts between win_from and win_to and pj is not null)
  select
    -- 2. carry decisions (as 0032)
    count(*) filter (where carried and device_time is distinct from prev_dt),
    count(*) filter (where carried and
      (j - 'ts' - 'carried' - 'status' - 'device_time' - 'pv_w' - 'pv_today_kwh' - 'pv_total_kwh')
      <> (pj - 'ts' - 'carried' - 'status' - 'device_time' - 'pv_w' - 'pv_today_kwh' - 'pv_total_kwh')),
    -- 3. tier decisions on fetched rows
    count(*) filter (where not carried and load_fetched_ts <> ts
      and (prev_load_w is null or ts - coalesce(prev_lft, 0) >= 300 or coalesce(prev_outage, false))),
    count(*) filter (where not carried and load_fetched_ts = ts and not refresh_min
      and not (prev_load_w is null or ts - coalesce(prev_lft, 0) >= 300 or coalesce(prev_outage, false) or coalesce(this_outage, false))),
    count(*) filter (where not carried and output_fetched_ts <> ts
      and (ts - coalesce(prev_oft, 0) >= 600 or coalesce(prev_outage, false))),
    count(*) filter (where not carried and output_fetched_ts = ts and not refresh_min
      and not (ts - coalesce(prev_oft, 0) >= 600 or coalesce(prev_outage, false) or coalesce(this_outage, false))),
    count(*) filter (where not carried and (load_fetched_ts is null or output_fetched_ts is null)),
    -- 4. derived load: the balance holds on real reads; derived rows follow it exactly
    count(*) filter (where not carried and load_fetched_ts = ts),
    count(*) filter (where not carried and load_fetched_ts = ts
      and abs(load_w - (pv_w + grid_w - batt_w)) <= 150),
    count(*) filter (where not carried and load_fetched_ts <> ts),
    count(*) filter (where not carried and load_fetched_ts <> ts
      and load_w <> greatest(0, round(pv_w + grid_w - batt_w)))
    into c_bad_dt, v_mismatch, t_load_missed, t_load_extra, t_out_missed, t_out_extra, t_null_ts,
         d_fetched, d_fetched_ok, d_derived, d_derived_bad
    from w;
  c_missed := 0;

  -- 5. call budget: normal minutes 2..10, refresh minutes 13
  with resp as (
    select (content::jsonb)->'results'->0 as r
      from net._http_response
     where content::text like '%"apiCalls"%' order by created desc limit 30)
  select count(*),
         count(*) filter (where not (
           ((r->>'listRefreshed')::boolean and (r->>'apiCalls')::int = 13) or
           (not (r->>'listRefreshed')::boolean and (r->>'apiCalls')::int between 2 and 10))),
         round(avg((r->>'apiCalls')::int), 2)
    into n_resp, n_bad_calls, avg_calls from resp;

  -- 6. health, 7. nothing else moved
  stale := public.api_health()->>'stale';
  select count(*) into n_plants from public.plant_users;
  select count(*) into n_bad_acc from private.sunsynk_accounts where status <> 'active' or last_error is not null;

  report := format(
    'win=%s..%s minutes=%s gaps60=%s short_inv=%s short_agg=%s gaprecs=%s | carried_dt_moved=%s mismatch=%s | load_missed=%s load_extra=%s out_missed=%s out_extra=%s null_ts=%s | fetched=%s fetched_ok=%s derived=%s derived_bad=%s | resp=%s bad_calls=%s avg_calls=%s | stale=%s plants=%s bad_acc=%s',
    win_from, win_to, n_ts, n_ts_gap, n_inv_short, n_agg_short, n_gaps, c_bad_dt, v_mismatch,
    t_load_missed, t_load_extra, t_out_missed, t_out_extra, t_null_ts,
    d_fetched, d_fetched_ok, d_derived, d_derived_bad, n_resp, n_bad_calls, avg_calls, stale, n_plants, n_bad_acc);
  raise notice '%', report;
  create temp table if not exists _verify_report (report text); delete from _verify_report;
  insert into _verify_report values (report);

  if n_ts <> 30 or n_ts_gap <> 0 or n_inv_short <> 0 or n_agg_short <> 0 or n_gaps <> 0
    then raise exception 'FAIL 1 rows missing: %', report; end if;
  if c_bad_dt <> 0 or v_mismatch <> 0 then raise exception 'FAIL 2 carry: %', report; end if;
  if t_load_missed <> 0 or t_load_extra <> 0 or t_out_missed <> 0 or t_out_extra <> 0 or t_null_ts <> 0
    then raise exception 'FAIL 3 tier decisions: %', report; end if;
  if d_fetched = 0 or d_fetched_ok < ceil(0.95 * d_fetched) or d_derived_bad <> 0
    then raise exception 'FAIL 4 derived load: %', report; end if;
  if n_resp <> 30 or n_bad_calls <> 0 or avg_calls > 6.0 then raise exception 'FAIL 5 call budget: %', report; end if;
  if stale <> 'false' then raise exception 'FAIL 6 health stale: %', report; end if;
  if n_plants <> 1 or n_bad_acc <> 0 then raise exception 'FAIL 7 accounts/plants: %', report; end if;
  update _verify_report v set report = 'verify_0033: PASS | ' || v.report;
end $$;
select report from _verify_report;
