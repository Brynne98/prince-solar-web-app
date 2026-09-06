-- verify-0036: readings/strings partitioned (0035), checked >= 30 minutes after
-- `supabase db push`. Row counts are compared by the caller (scripts/verify.sh has
-- no snapshot for them; take `select count(*)` of both tables before the push and
-- compare with the report).
--   scripts/verify.sh scripts/sql/verify-0036.sql check <snapshot-file>
do $$
declare
  win_from bigint; win_to bigint;
  n_ts int; n_ts_gap int; n_inv_short int; n_agg_short int; n_gaps int;
  r_children int; s_children int; months_in_data int; r_rows bigint; s_rows bigint;
  plan text; plan_parts int; t0 timestamptz; ms_overview numeric;
  stale text; n_bad_acc int; n_jobs int; report text;
begin
  select min(ts), max(ts) into win_from, win_to
    from (select distinct ts from public.readings order by ts desc limit 30) w;

  -- 1. the poller kept landing rows
  with w as (select distinct ts from public.readings where ts between win_from and win_to)
  select count(*), count(*) filter (where prev is not null and ts - prev <> 60) into n_ts, n_ts_gap
    from (select ts, lag(ts) over (order by ts) as prev from w) x;
  with per as (select sn, count(distinct ts) as n from public.readings where ts between win_from and win_to group by sn)
  select count(*) filter (where n <> 30) into n_inv_short from per;
  with per as (select plant_id, count(distinct ts) as n from public.agg_minute where ts between win_from and win_to group by plant_id)
  select count(*) filter (where n <> 30) into n_agg_short from per;
  select count(*) into n_gaps from private.gaps where to_ts >= win_from;

  -- 2. partition tree: one child per month on record plus two ahead
  select count(*) into r_children from pg_partition_tree('public.readings') where isleaf;
  select count(*) into s_children from pg_partition_tree('public.strings') where isleaf;
  select (extract(year from age(date_trunc('month', now()), date_trunc('month', to_timestamp(min(ts))))) * 12
        + extract(month from age(date_trunc('month', now()), date_trunc('month', to_timestamp(min(ts))))))::int + 1
    into months_in_data from public.readings;
  select count(*), (select count(*) from public.strings) into r_rows, s_rows from public.readings;

  -- 3. the per-minute hot path (inverters_cached's last-row scan) prunes every
  --    closed month at run time: only the current child and the empty ones ahead
  --    are executed (the floor is a stable expression, so pruning is initial-time,
  --    which plain EXPLAIN does not show).
  plan_parts := 0;
  for plan in execute 'explain (analyze, costs off, timing off, summary off) select to_jsonb(r) from public.readings r where r.sn = ''x'' and r.ts > extract(epoch from now())::bigint - 86400 order by r.ts desc limit 1' loop
    if plan ~ 'readings_y\d{4}m\d{2}' and plan !~ 'never executed' then plan_parts := plan_parts + 1; end if;
  end loop;

  -- 4. the overview's read pattern (latest ts for the plant, then that minute's rows)
  t0 := clock_timestamp();
  perform r.* from public.readings r
    where r.plant_id = (select plant_id from public.plant_users limit 1)
      and r.ts = (select max(ts) from public.readings where plant_id = (select plant_id from public.plant_users limit 1));
  perform s.* from public.strings s
    where s.plant_id = (select plant_id from public.plant_users limit 1)
      and s.ts = (select max(ts) from public.readings where plant_id = (select plant_id from public.plant_users limit 1));
  ms_overview := round(extract(milliseconds from clock_timestamp() - t0)::numeric, 1);

  -- 5. health, accounts, cron jobs present
  stale := public.api_health()->>'stale';
  select count(*) into n_bad_acc from private.sunsynk_accounts where status <> 'active' or last_error is not null;
  n_jobs := 0;
  if to_regclass('cron.job') is not null then
    execute 'select count(*) from cron.job where jobname in (''ensure-partitions'', ''downsample-strings'')' into n_jobs;
  end if;

  report := format(
    'win=%s..%s minutes=%s gaps60=%s short_inv=%s short_agg=%s gaprecs=%s | readings_children=%s strings_children=%s months_in_data=%s rows_readings=%s rows_strings=%s | plan_partition_lines=%s | overview_ms=%s | stale=%s bad_acc=%s cron_jobs=%s',
    win_from, win_to, n_ts, n_ts_gap, n_inv_short, n_agg_short, n_gaps, r_children, s_children, months_in_data,
    r_rows, s_rows, plan_parts, ms_overview, stale, n_bad_acc, n_jobs);
  raise notice '%', report;
  create temp table if not exists _verify_report (report text); delete from _verify_report;
  insert into _verify_report values (report);

  if n_ts <> 30 or n_ts_gap <> 0 or n_inv_short <> 0 or n_agg_short <> 0 or n_gaps > 1
    then raise exception 'FAIL 1 rows missing: %', report; end if;
  if r_children < months_in_data + 2 or s_children < months_in_data + 2
    then raise exception 'FAIL 2 partition tree: %', report; end if;
  if plan_parts < 1 or plan_parts > 4 then raise exception 'FAIL 3 pruning: %', report; end if;
  if ms_overview > 500 then raise exception 'FAIL 4 overview read slow: %', report; end if;
  if stale <> 'false' or n_bad_acc <> 0 or n_jobs <> 2 then raise exception 'FAIL 5 health/cron: %', report; end if;
  update _verify_report v set report = 'verify_0036: PASS | ' || v.report;
end $$;
select report from _verify_report;
