do $$
declare
  deploy_from bigint := extract(epoch from now())::bigint - 15 * 60;
  n_gaps int; stale text; n_resp int; n_refreshed int; n_calls_11 int; n_calls_10 int;
  bad_status int; null_dt int; n_master int; n_slave int; n_plants int; report text;
begin
  -- 4. continuity
  select count(*) into n_gaps from private.gaps where to_ts >= deploy_from;
  stale := public.api_health()->>'stale';

  -- 5. fewer calls, last 10 poll responses
  with resp as (
    select (content::jsonb)->'results'->0 as r
      from net._http_response
     where content::text like '%"apiCalls"%' order by created desc limit 10)
  select count(*),
         count(*) filter (where (r->>'listRefreshed')::boolean),
         -- refresh minute: 10 realtime + inverter list + plant list + 1 plant detail = 13
         count(*) filter (where (r->>'apiCalls')::int = 13 and (r->>'listRefreshed')::boolean),
         count(*) filter (where (r->>'apiCalls')::int = 10 and not (r->>'listRefreshed')::boolean)
    into n_resp, n_refreshed, n_calls_11, n_calls_10 from resp;

  -- 6. cache complete, 7. device_time, over the last 10 minutes of readings
  with last10 as (select distinct ts from public.readings order by ts desc limit 10)
  select count(*) filter (where r.status is null), count(*) filter (where r.device_time is null),
         count(distinct r.device_time) filter (where r.sn = '2508290475'),
         count(distinct r.device_time) filter (where r.sn = '2512082438')
    into bad_status, null_dt, n_master, n_slave
    from public.readings r join last10 on last10.ts = r.ts;

  -- 8. plants untouched
  select count(*) into n_plants from public.plant_users;

  report := format('gaps=%s stale=%s responses=%s refreshed=%s calls11=%s calls10=%s null_status=%s null_device_time=%s distinct_dt_master=%s distinct_dt_slave=%s plants=%s',
                   n_gaps, stale, n_resp, n_refreshed, n_calls_11, n_calls_10, bad_status, null_dt, n_master, n_slave, n_plants);
  raise notice '%', report;

  if n_gaps <> 0 then raise exception 'FAIL 4 gap during deploy: %', report; end if;
  if stale <> 'false' then raise exception 'FAIL 4 health stale: %', report; end if;
  if n_resp <> 10 or n_refreshed <> 1 or n_calls_11 <> 1 or n_calls_10 <> 9 then raise exception 'FAIL 5 call counts: %', report; end if;
  if bad_status <> 0 then raise exception 'FAIL 6 status null on cached minute: %', report; end if;
  if null_dt <> 0 or n_slave > 3 or n_master < 8 then raise exception 'FAIL 7 device_time: %', report; end if;
  if n_plants <> 1 then raise exception 'FAIL 8 plant_users changed: %', report; end if;
  raise notice 'verify_0031: PASS';
end $$;
