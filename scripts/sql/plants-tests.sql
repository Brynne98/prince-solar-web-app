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

-- R23: app and mail read the same figure
do $$
declare p bigint := plants.plant_for('sunsynk', 'r23-1'); d date := public.today_tz(plants.tz(p));
        t0 bigint := public.day_start_epoch_tz(d, plants.tz(p)); app jsonb; mail jsonb; i int;
begin
  perform set_config('billing.guarded', 'on', true);   -- as the reader's save: no seat needed here
  for i in 0..59 loop   -- an hour: 3 kW solar, 2 kW home, 400 W bought, battery 40 -> 59 %
    insert into public.agg_minute (ts, plant_id, pv_w, load_w, batt_w, grid_w, soc, source)
    values (t0 + 3600 + i * 60, p, 3000, 2000, -1400, 400, 40 + (i * 0.33), 'poller');
  end loop;
  select public._energy_row('day', e.period, e.pv_kwh, e.load_kwh, e.imp_kwh, e.exp_kwh, e.chg_kwh, e.dischg_kwh) into app
    from public._plant_day_energy(p, d, d) e;
  mail := public.span_figures(p, d, d);
  perform pg_temp.ok('R23 independence: the app''s day = the mail''s',
    (app->>'selfSuff')::numeric = round((mail->>'independence_pct')::numeric), format('%s %s', app->>'selfSuff', mail->>'independence_pct'));
  perform pg_temp.ok('R23 solar kWh: the app''s day = the mail''s', (app->>'pv')::numeric = (mail->>'made_kwh')::numeric,
    format('%s %s', app->>'pv', mail->>'made_kwh'));
  perform pg_temp.ok('R23 battery %: the newest minute in the 10 up to the time',
    public.soc_at(p, t0 + 3600 + 59 * 60) = round(40 + 59 * 0.33) and public.soc_at(p, t0 + 3600 + 59 * 60 + 601) is null);
end $$;

-- R20: a save checks the route on the database's clock, not the time the caller sends
do $$
declare u uuid := gen_random_uuid(); a uuid; l uuid; p bigint; r jsonb; v bigint;
begin
  insert into auth.users (id, email, created_at, email_confirmed_at) values (u, 'r20@x.test', now() - interval '2 days', now() - interval '2 days');
  insert into billing.accounts (user_id, market, created_at) values (u, 'ZA', now() - interval '2 days') returning id into a;
  l := plants.link_login(a, 'sunsynk', 'r20@x.test', '[{"vendor_id":"r20-1","name":"R20"}]', now() - interval '2 days');
  p := plants.plant_for('sunsynk', 'r20-1');
  perform billing.set_chosen_plants(a, array[p], now() - interval '2 days');
  v := (select version from plants.plants where id = p);
  update billing.seats set closed_at = now() - interval '1 second', close_reason = 'switched' where plant = p and closed_at is null;
  -- the read started a minute ago, when the seat was open; it arrives now, after it closed
  r := public.poll_commit_v2(jsonb_build_object(p::text, v), l, (extract(epoch from now())::bigint / 60) * 60 - 60,
         '[]', '[]', jsonb_build_array(jsonb_build_object('plant_id', p, 'pv_w', 5)), '[]', '[]', null, null, now() - interval '1 minute');
  perform pg_temp.ok('R20 a save after the route ended, with an old time, is refused', r->'refused' = jsonb_build_array(p), r::text);
  perform pg_temp.ok('R20 ... and writes nothing', not exists (select 1 from public.agg_minute where plant_id = p));
end $$;

-- R13, R14: the fake plants' logins are brand mock; the grid rule is one function
do $$
begin
  perform pg_temp.ok('R14 a login ending @mock is brand mock', plants.brand_for_username('Tester@Mock') = 'mock'
    and plants.brand_for_username('owner@example.com') = plants.default_brand());
  perform pg_temp.ok('R14 no mock plant keeps an old id', not exists (select 1 from plants.plants where brand = 'mock' and id < 1000000000000));
  perform pg_temp.ok('R13 no mock inverter keeps a bare serial', not exists (select 1 from private.inverters i
    join plants.plants p on p.id = i.plant_id where p.brand = 'mock' and i.sn not like 'mock:%'));
  perform pg_temp.ok('R23 grid present: over 100 V, one rule', public.grid_live(100.1) and not public.grid_live(100) and public.grid_live(null) is null);
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
