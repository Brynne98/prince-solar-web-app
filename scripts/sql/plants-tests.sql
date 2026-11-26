-- SOLAR-681: logins and plants (reports/rework-step-2-logins-plants-reading.md). Each check names
-- its rule. LOCAL database only, with every migration applied. One transaction, rolled back:
--   psql "$DB" -v ON_ERROR_STOP=1 -f scripts/sql/plants-tests.sql
-- Exit 0: every check passed. A failed check raises, so psql exits 3.

begin;
set client_min_messages = notice;

create temp table t_results (n serial, label text, pass boolean, detail text);
create function pg_temp.ok(p_label text, p_cond boolean, p_detail text default null)
returns void language sql as $$
  insert into t_results (label, pass, detail) values (p_label, coalesce(p_cond, false), p_detail)
$$;

-- R24: api_link_disconnect is gone (it skipped billing's half of a remove)
do $$
begin
  perform pg_temp.ok('R24 api_link_disconnect is gone', to_regproc('public.api_link_disconnect') is null);
end $$;

-- R10, R11: our own ids; one plant per brand and brand id; only plant_for makes one
do $$
declare a bigint; b bigint; c bigint; refused boolean := false;
begin
  a := plants.plant_for('sunsynk', 'p681-1');
  b := plants.plant_for('sunsynk', 'p681-1');
  perform pg_temp.ok('R10 a new plant takes an id from 1e12 up', a >= 1000000000000, a::text);
  perform pg_temp.ok('R11 the same brand and brand id: the same plant', a = b);
  begin
    insert into plants.plants (id, brand, vendor_id, time_zone) values (495944, 'sunsynk', 'p681-x', 'UTC');
  exception when others then refused := true;
  end;
  perform pg_temp.ok('R10 an id below 1e12 is refused for a new plant', refused);
  -- R12: brand B's id equal to an existing plant's own id is another plant
  c := plants.plant_for('mock', a::text);
  perform pg_temp.ok('R12 another brand with the same id: another plant', c <> a and plants.brand_of(c) = 'mock');
  perform pg_temp.ok('R26 a new plant takes its market''s zone', plants.tz(a) = plants.market_tz());
end $$;

-- R4, R6: one set of status words; the browser cannot read logins
do $$
declare refused boolean := false;
begin
  begin
    insert into plants.logins (user_id, brand, kind, username, status)
    values ((select id from auth.users limit 1), 'sunsynk', 'share', 'r4@x.test', 'active');
  exception when check_violation then refused := true;
  end;
  perform pg_temp.ok('R4 status active is refused (ok, needs_reconnect, disabled)', refused);
  perform pg_temp.ok('R6 authenticated and anon cannot read plants.logins',
    not has_table_privilege('authenticated', 'plants.logins', 'select') and not has_table_privilege('anon', 'plants.logins', 'select'));
  perform pg_temp.ok('R3 the old tables are gone',
    to_regclass('private.sunsynk_accounts') is null and to_regclass('public.plant_users') is null and to_regclass('billing.logins') is null);
end $$;

-- R17: one brand down does not make another brand down
do $$
declare u uuid; i int;
begin
  insert into auth.users (id, email) values (gen_random_uuid(), 'r17@x.test') returning id into u;
  update plants.logins set last_try = null where true;
  for i in 1..3 loop
    insert into plants.logins (user_id, account, brand, kind, username, status, last_try, last_try_at, linked_at)
    values (u, billing.account_of(u), 'mock', 'login', 'r17-' || i || '@mock', 'ok', 'vendor', now(), now() - interval '1 hour');
  end loop;
  update plants.brand_state set down = false, clear_since = null, up_at = null;
  perform public.email_sweep();
  perform pg_temp.ok('R17 mock down', (select down from plants.brand_state where brand = 'mock'));
  perform pg_temp.ok('R17 sunsynk not down with it', not (select down from plants.brand_state where brand = 'sunsynk'));
end $$;

-- R26: a signed-in call reaches the plant's zone (plants is not the browser's schema)
do $$
declare z text; err text;
begin
  begin
    set local role authenticated;
    z := public.plant_tz(1);
  exception when others then err := sqlerrm;
  end;
  reset role;
  perform pg_temp.ok('R26 plant_tz as authenticated', err is null and z is not null, err);
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r record; bad int := 0;
begin
  for r in select * from t_results order by n loop
    if r.pass then raise notice 'ok    %', r.label;
    else raise notice 'FAIL  %  (%)', r.label, r.detail; bad := bad + 1; end if;
  end loop;
  if bad > 0 then raise exception '% of % checks failed', bad, (select count(*) from t_results); end if;
  raise notice 'all % checks passed', (select count(*) from t_results);
end $$;
rollback;
