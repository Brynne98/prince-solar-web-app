-- SOLAR-659 (0277): the background delete run. Not in one transaction: the run commits, so
-- it is called at top level here. Every row it makes is for plants 990659xxx and is removed
-- at the end. Run by scripts/history-delete-run-test.mjs.

set client_min_messages = warning;
create temp table t_results (n serial, label text, pass boolean, detail text);
create function pg_temp.ok(p_label text, p_cond boolean, p_detail text default null)
returns void language sql as $$
  insert into t_results (label, pass, detail) values (p_label, coalesce(p_cond, false), p_detail)
$$;
-- every row of a plant, in the tables the run clears
create function pg_temp.left_rows(p bigint) returns bigint language sql as $$
  select (select count(*) from public.readings where plant_id = p) + (select count(*) from public.strings where plant_id = p)
       + (select count(*) from public.readings_5m where plant_id = p) + (select count(*) from public.strings_5m where plant_id = p)
       + (select count(*) from public.agg_minute where plant_id = p) + (select count(*) from public.agg_5m where plant_id = p)
       + (select count(*) from public.inverter_history where plant_id = p) + (select count(*) from public.inverter_history_5m where plant_id = p)
       + (select count(*) from public.plant_energy where plant_id = p) + (select count(*) from public.grid_off where plant_id = p)
       + (select count(*) from private.gaps where plant_id = p) + (select count(*) from private.grid_off_progress where plant_id = p)
$$;
-- n minutes of rows for a plant, ending an hour ago (inside today's raw partitions)
create function pg_temp.fill(p bigint, n int) returns void language plpgsql as $$
declare t0 bigint := (extract(epoch from now())::bigint / 300) * 300 - 3600 - n * 60;
begin
  perform set_config('billing.guarded', 'on', false);
  insert into public.readings (plant_id, sn, ts) select p, 'sn' || p, t0 + i * 60 from generate_series(1, n) i;
  insert into public.strings (plant_id, sn, no, ts) select p, 'sn' || p, k, t0 + i * 60 from generate_series(1, n) i, generate_series(1, 2) k;
  insert into public.agg_minute (plant_id, ts) select p, t0 + i * 60 from generate_series(1, n) i;
  insert into public.inverter_history (plant_id, sn, ts) select p, 'sn' || p, t0 + i * 60 from generate_series(1, n) i;
  insert into public.readings_5m (plant_id, sn, ts) select p, 'sn' || p, t0 + i * 300 from generate_series(1, n / 5) i;
  insert into public.strings_5m (plant_id, sn, no, ts) select p, 'sn' || p, 1, t0 + i * 300 from generate_series(1, n / 5) i;
  insert into public.agg_5m (plant_id, ts, n, n_poller) select p, t0 + i * 300, 5, 5 from generate_series(1, n / 5) i;
  insert into public.inverter_history_5m (plant_id, sn, ts, n) select p, 'sn' || p, t0 + i * 300, 5 from generate_series(1, n / 5) i;
  insert into public.plant_energy (plant_id, bucket, period) values (p, 'day', current_date);
  insert into public.grid_off (plant_id, started_at, last_off_at, minutes_off) values (p, now() - interval '2 hours', now() - interval '1 hour', 60);
  insert into private.gaps (plant_id, from_ts, to_ts) values (p, t0, t0 + 60);
  insert into private.grid_off_progress (plant_id, through_ts) values (p, t0);
  perform set_config('billing.guarded', 'off', false);
end $$;
create function pg_temp.clear() returns void language plpgsql as $$
declare p bigint;
begin
  for p in select x from generate_series(990659001, 990659009) x loop
    perform private.plant_readings_delete(p);
  end loop;
  delete from private.history_delete_queue where plant_id between 990659001 and 990659009;
  delete from private.history_delete_log where plant_id between 990659001 and 990659009;
end $$;

select pg_temp.clear();

-- D1: a listed plant is cleared in batches; a plant not listed is left alone
select pg_temp.fill(990659001, 40), pg_temp.fill(990659002, 10);
insert into private.history_delete_queue (plant_id) values (990659001);
call private.history_delete_run(interval '45 seconds', 7);
select pg_temp.ok('D1 listed plant: every row gone', pg_temp.left_rows(990659001) = 0, pg_temp.left_rows(990659001)::text);
select pg_temp.ok('D1 ... off the list', not private.history_deleting(990659001));
select pg_temp.ok('D1 other plant untouched', pg_temp.left_rows(990659002) = 10 + 20 + 10 + 10 + 4 * 2 + 4,
                  pg_temp.left_rows(990659002)::text);
select pg_temp.ok('D1 one log row, caller worker, counts of what went',
  (select count(*) = 1 and min(caller) = 'worker' and min((counts->>'readings')::int) = 40
          and min((counts->>'strings')::int) = 80 and min((counts->>'agg_5m')::int) = 8
     from private.history_delete_log where plant_id = 990659001),
  (select string_agg(caller || ' ' || counts::text, '; ') from private.history_delete_log where plant_id = 990659001));

-- D2: cut off by its time cap, it carries on in the next run
select pg_temp.fill(990659003, 30);
insert into private.history_delete_queue (plant_id) values (990659003);
call private.history_delete_run(interval '0 seconds', 5);
select pg_temp.ok('D2 a run over its cap starts nothing', pg_temp.left_rows(990659003) > 0 and private.history_deleting(990659003));
call private.history_delete_run(interval '45 seconds', 5);
select pg_temp.ok('D2 the next run finishes it', pg_temp.left_rows(990659003) = 0 and not private.history_deleting(990659003));

-- D3: writers with no version check skip a listed plant
select pg_temp.fill(990659004, 10);
insert into private.history_delete_queue (plant_id) values (990659004);
select pg_temp.ok('D3 inverter prune skips it', public.q_prune_inverter_history(990659004, 0) = 0
                  and (select count(*) from public.inverter_history where plant_id = 990659004) = 10);
select pg_temp.ok('D3 grid-off update skips it', private.grid_off_update(990659004) = 0);
select private.agg_minute_rollup(0);
select pg_temp.ok('D3 minute rollup writes no 5-minute rows for it',
  (select count(*) from public.agg_5m where plant_id = 990659004) = 2);
call private.history_delete_run(interval '45 seconds', 5000);
select pg_temp.ok('D3 then cleared', pg_temp.left_rows(990659004) = 0);

-- D4: a plant listed with nothing stored but a little: fenced, cleared, logged
select pg_temp.fill(990659005, 5);
insert into private.history_delete_queue (plant_id) values (990659005);
call private.history_delete_run(interval '45 seconds', 5000);
select pg_temp.ok('D4 ... fenced and cleared',
  pg_temp.left_rows(990659005) = 0 and exists (select 1 from private.history_delete_log where plant_id = 990659005));

-- D5: the alarm: a plant listed over an hour fails the check; worker rows don't trip the 3 s limit
insert into private.history_delete_log (plant_id, caller, wait_ms, raw_ms, rest_ms, counts)
values (990659006, 'worker', 0, 9000, 9000, '{}');
-- the check commits, so it runs at top level; psql keeps its error for the check after it
\set ON_ERROR_STOP 0
call private.history_delete_check();
select pg_temp.ok('D5 a slow worker delete: no alarm', not :ERROR, :'LAST_ERROR_MESSAGE');
insert into private.history_delete_queue (plant_id, queued_at) values (990659007, now() - interval '2 hours');
call private.history_delete_check();
select pg_temp.ok('D5 listed over an hour: alarm', :ERROR and :'LAST_ERROR_MESSAGE' like '%plant 990659007 waiting%', :'LAST_ERROR_MESSAGE');
\set ON_ERROR_STOP 1

select pg_temp.clear();

do $$
declare r record; f int; n int;
begin
  for r in select * from t_results order by n loop
    raise warning '%  %  (%)', case when r.pass then 'ok  ' else 'FAIL' end, r.label, r.detail;
  end loop;
  select count(*) filter (where not pass), count(*) into f, n from t_results;
  raise warning '% checks, % failed', n, f;
  if f > 0 then raise exception 'history delete run test failed'; end if;
end $$;
