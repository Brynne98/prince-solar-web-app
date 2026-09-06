-- verify-0032: the freshness gate, checked over the last 30 logged minutes.
-- Run >= 30 minutes after deploying 0032 + poll:
--   supabase db query --linked -f scripts/sql/verify-0032.sql
-- Raises on the first failed criterion, so the exit code decides. The alerts
-- comparison (criterion 7) is done by scripts/verify.sh against a snapshot
-- taken before the deploy; this script prints the current hash in its report.
do $$
declare
  win_from bigint; win_to bigint;
  n_ts int; n_ts_gap int; n_inv int; n_inv_short int; n_agg_short int; n_gaps int;
  c_bad_dt int; c_missed int;
  dt_master int; dt_slave int;
  g_outage int; g_run int; g_refresh int;
  v_mismatch int; v_stale_pv int;
  n_resp int; n_bad_calls int; avg_calls numeric;
  stale text; alerts_md5 text;
  n_plants int; n_bad_acc int;
  report text;
begin
  -- window: the last 30 distinct minutes in readings
  select min(ts), max(ts) into win_from, win_to
    from (select distinct ts from public.readings order by ts desc limit 30) w;

  -- 1. every row lands: 30 minutes 60 s apart, every inverter every minute, agg per plant per minute
  with w as (select distinct ts from public.readings where ts between win_from and win_to)
  select count(*), count(*) filter (where prev is not null and ts - prev <> 60) into n_ts, n_ts_gap
    from (select ts, lag(ts) over (order by ts) as prev from w) x;
  with per as (select sn, count(distinct ts) as n from public.readings where ts between win_from and win_to group by sn)
  select count(*), count(*) filter (where n <> 30) into n_inv, n_inv_short from per;
  with per as (select plant_id, count(distinct ts) as n from public.agg_minute where ts between win_from and win_to group by plant_id)
  select count(*) filter (where n <> 30) into n_agg_short from per;
  select count(*) into n_gaps from private.gaps where to_ts >= win_from;

  -- 2. skips only when truly stale; 4. guard rails proven; 5. carried values exact
  with r as (
    select r.*, to_jsonb(r) as j,
           lag(to_jsonb(r)) over (partition by sn order by ts) as pj,
           lag(device_time) over (partition by sn order by ts) as prev_dt,
           lag(grid_relay_status) over (partition by sn order by ts) as prev_relay,
           lag(grid_volt_v) over (partition by sn order by ts) as prev_volt,
           -- carried rows before this one since the last fetched row
           row_number() over (partition by sn, grp order by ts) - 1 as run_before
      from (select r.*, sum(case when carried then 0 else 1 end) over (partition by sn order by ts) as grp
              from public.readings r
             where r.ts between win_from - 6 * 60 and win_to) r),
    w as (select * from r where ts between win_from and win_to and pj is not null)
  select
    -- carried but device_time moved
    count(*) filter (where carried and device_time is distinct from prev_dt),
    -- fetched although nothing new and no guard applied
    count(*) filter (where not carried and device_time = prev_dt
                       and (ts / 60) % 10 <> 0 and run_before < 5
                       and prev_relay is distinct from '0' and coalesce(prev_volt, 999) >= 100),
    count(*) filter (where carried and (prev_relay = '0' or prev_volt < 100)),
    count(*) filter (where carried and run_before >= 5),
    count(*) filter (where carried and (ts / 60) % 10 = 0),
    -- carried row differs from the previous row outside the fresh input fields
    count(*) filter (where carried and
      (j - 'ts' - 'carried' - 'status' - 'device_time' - 'pv_w' - 'pv_today_kwh' - 'pv_total_kwh')
      <> (pj - 'ts' - 'carried' - 'status' - 'device_time' - 'pv_w' - 'pv_today_kwh' - 'pv_total_kwh'))
    into c_bad_dt, c_missed, g_outage, g_run, g_refresh, v_mismatch
    from w;

  -- 5b. strings on a carried minute are stored (fresh from input), one set per inverter-minute
  select count(*) into v_stale_pv
    from public.readings r
   where r.ts between win_from and win_to and r.carried
     and not exists (select 1 from public.strings s where s.ts = r.ts and s.sn = r.sn);

  -- 3. no missed uploads
  select count(distinct device_time) filter (where sn = '2508290475'),
         count(distinct device_time) filter (where sn = '2512082438')
    into dt_master, dt_slave
    from public.readings where ts between win_from and win_to;

  -- 6. call budget, from the last 30 poll responses
  with resp as (
    select (content::jsonb)->'results'->0 as r
      from net._http_response
     where content::text like '%"apiCalls"%' order by created desc limit 30)
  select count(*),
         count(*) filter (where not (
           ((r->>'listRefreshed')::boolean and (r->>'apiCalls')::int = 13) or
           (not (r->>'listRefreshed')::boolean and (r->>'apiCalls')::int in (2, 6, 10)))),
         round(avg((r->>'apiCalls')::int), 2)
    into n_resp, n_bad_calls, avg_calls from resp;

  -- 7. health + alerts hash (compared by the shell wrapper)
  stale := public.api_health()->>'stale';
  select md5(coalesce(jsonb_agg(to_jsonb(a) order by a.key)::text, '[]')) into alerts_md5
    from public.plant_users pu, public.api_alerts_due(pu.plant_id) a;

  -- 8. nothing else moved
  select count(*) into n_plants from public.plant_users;
  select count(*) into n_bad_acc from private.sunsynk_accounts
   where status <> 'active' or last_error is not null;

  report := format(
    'win=%s..%s minutes=%s gaps60=%s inverters=%s short_inv=%s short_agg=%s gaprecs=%s | carried_dt_moved=%s missed_skips=%s | dt_master=%s dt_slave=%s | g_outage=%s g_run=%s g_refresh=%s | mismatch=%s no_strings=%s | resp=%s bad_calls=%s avg_calls=%s | stale=%s alerts_md5=%s | plants=%s bad_acc=%s',
    win_from, win_to, n_ts, n_ts_gap, n_inv, n_inv_short, n_agg_short, n_gaps,
    c_bad_dt, c_missed, dt_master, dt_slave, g_outage, g_run, g_refresh,
    v_mismatch, v_stale_pv, n_resp, n_bad_calls, avg_calls, stale, alerts_md5, n_plants, n_bad_acc);
  raise notice '%', report;
  -- the CLI does not surface notices; hand the report back as a row too
  create temp table if not exists _verify_report (report text); delete from _verify_report;
  insert into _verify_report values (report);

  if n_ts <> 30 or n_ts_gap <> 0 or n_inv_short <> 0 or n_agg_short <> 0 or n_gaps <> 0
    then raise exception 'FAIL 1 rows missing: %', report; end if;
  if c_bad_dt <> 0 or c_missed <> 0 then raise exception 'FAIL 2 skip decision: %', report; end if;
  if dt_master < 24 or dt_slave > 8 then raise exception 'FAIL 3 uploads: %', report; end if;
  if g_outage <> 0 or g_run <> 0 or g_refresh <> 0 then raise exception 'FAIL 4 guard rails: %', report; end if;
  if v_mismatch <> 0 or v_stale_pv <> 0 then raise exception 'FAIL 5 carried values: %', report; end if;
  if n_resp <> 30 or n_bad_calls <> 0 or avg_calls > 7.5 then raise exception 'FAIL 6 call budget: %', report; end if;
  if stale <> 'false' then raise exception 'FAIL 7 health stale: %', report; end if;
  if n_plants <> 1 or n_bad_acc <> 0 then raise exception 'FAIL 8 accounts/plants: %', report; end if;
  raise notice 'verify_0032: PASS';
  update _verify_report v set report = 'verify_0032: PASS | ' || v.report;
end $$;
select report from _verify_report;
