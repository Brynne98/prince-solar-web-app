-- inverters_cached with two logins on one plant (SOLAR-575, 0220). Login A polls the
-- plant every minute; login B's hourly sync files the serials under B. A's cache must
-- still hold them, before and after the sync, or A re-reads the lists every minute.
-- Needs the local database at the latest migration. Runs in one transaction, rolled back.
--   docker exec -i supabase_db_sunsynk-dashboard psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 < scripts/sql/inverters-cached-tests.sql
-- Exit code decides: any wrong case raises.
\set ON_ERROR_STOP 1
begin;
create temp table t(step text, got text, want text);
insert into auth.users (id, email) values
  ('7a1e0c52-5750-4d5b-9b1e-000000000575', 'cache-a@t.test'),
  ('7a1e0c52-5750-4d5b-9b1e-000000000576', 'cache-b@t.test')
on conflict (id) do nothing;
do $$
declare
  ua uuid := '7a1e0c52-5750-4d5b-9b1e-000000000575';
  ub uuid := '7a1e0c52-5750-4d5b-9b1e-000000000576';
  a uuid; b uuid; p bigint := plants.plant_for('sunsynk', '990575'); other bigint := plants.plant_for('sunsynk', '990576');
  cached_a text; cached_b text;
begin
  a := public.account_upsert(ua, 'cache-a@local.test', 'tok', 9999999999999);
  b := public.account_upsert(ub, 'cache-b@local.test', 'tok', 9999999999999);
  insert into plants.login_plants (login, plant, plant_name) values
    (a, p, 'Two logins'), (b, p, 'Two logins'), (b, other, 'B only');

  -- A's minute commit files the serials under A
  perform public.inverters_seed(jsonb_build_array(
    jsonb_build_object('sn', 'SOL575A', 'plant_id', p, 'account_id', a),
    jsonb_build_object('sn', 'SOL575B', 'plant_id', p, 'account_id', a),
    jsonb_build_object('sn', 'SOL575C', 'plant_id', other, 'account_id', b)));
  select string_agg(sn, ',' order by sn) into cached_a from public.inverters_cached(a);
  insert into t values ('A after own commit', cached_a, 'SOL575A,SOL575B');

  -- B's hourly sync polls the plant too and files the serials under B
  perform public.inverters_seed(jsonb_build_array(
    jsonb_build_object('sn', 'SOL575A', 'plant_id', p, 'account_id', b),
    jsonb_build_object('sn', 'SOL575B', 'plant_id', p, 'account_id', b)));
  insert into t values ('serials now under B',
    (select string_agg(distinct account_id::text, ',') from private.inverters where plant_id = p), b::text);
  select string_agg(sn, ',' order by sn) into cached_a from public.inverters_cached(a);
  insert into t values ('A after B sync', cached_a, 'SOL575A,SOL575B');
  select string_agg(sn, ',' order by sn) into cached_b from public.inverters_cached(b);
  insert into t values ('B sees both plants', cached_b, 'SOL575A,SOL575B,SOL575C');

  -- A's next commit takes them back; B still sees them
  perform public.inverters_seed(jsonb_build_array(
    jsonb_build_object('sn', 'SOL575A', 'plant_id', p, 'account_id', a),
    jsonb_build_object('sn', 'SOL575B', 'plant_id', p, 'account_id', a)));
  select string_agg(sn, ',' order by sn) into cached_b from public.inverters_cached(b);
  insert into t values ('B after A commit', cached_b, 'SOL575A,SOL575B,SOL575C');

  -- A login linked to no plant sees only what is filed under it
  delete from plants.login_plants where login = a;
  update private.inverters set account_id = b where plant_id = p;
  insert into t values ('A unlinked sees none', (select count(*)::text from public.inverters_cached(a)), '0');
end $$;
select step, got, want, case when got is not distinct from want then 'ok' else 'WRONG' end as result from t;
do $$ begin
  if exists (select 1 from t where got is distinct from want) then raise exception 'inverters-cached tests failed'; end if;
  raise notice 'all % checks passed', (select count(*) from t);
end $$;
rollback;
