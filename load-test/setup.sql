-- SOLAR-209 load test helpers. Load into a throwaway database only, never prod:
--   psql -f load-test/setup.sql
-- Fake plants are 900001.., two inverters each (sn LT<plant>A / LT<plant>B), one
-- user and one SunSynk login per plant. loadtest.cleanup() removes all of it.

create schema if not exists loadtest;
grant usage on schema loadtest to authenticated;

-- n inverters = n/2 plants. Adds what is missing; never removes.
create or replace function loadtest.add_fleet(p_inverters int)
returns int language plpgsql as $$
declare k int; pid bigint; uid uuid; aid uuid; have int;
begin
  select count(*) into have from public.plant_users where plant_id > 900000;
  for k in have + 1 .. p_inverters / 2 loop
    pid := 900000 + k;
    uid := gen_random_uuid();
    insert into auth.users (id, aud, role, email, email_confirmed_at)
      values (uid, 'authenticated', 'authenticated', 'lt' || k || '@loadtest.invalid', now());
    insert into private.sunsynk_accounts (user_id, sunsynk_username, access_token, access_expires_at, status, provider)
      values (uid, 'lt' || k, 'at:lt' || k, 4102444800000, 'active', 'sunsynk')  -- stack.mjs's token
      returning id into aid;
    insert into public.plant_users (plant_id, user_id, account_id, plant_name)
      values (pid, uid, aid, 'Load test ' || k);
    insert into public.plant_config (plant_id, timezone, has_grid, has_battery, batt_positive_means)
      values (pid, 'Africa/Johannesburg', true, true, 'charging')
      on conflict (plant_id) do nothing;
    insert into private.inverters (sn, plant_id, account_id)
      values ('LT' || pid || 'A', pid, aid), ('LT' || pid || 'B', pid, aid)
      on conflict do nothing;
  end loop;
  return (select count(*) from public.plant_users where plant_id > 900000) * 2;
end $$;

-- Bulk minute rows for plants [p_lo, p_hi] from p_from to p_to (epoch s), the
-- shape poll_commit stores. Setup only: not part of what is timed.
create or replace function loadtest.prefill(p_lo bigint, p_hi bigint, p_from bigint, p_to bigint)
returns bigint language plpgsql as $$
declare d date; n bigint;
begin
  for d in select generate_series(to_timestamp(p_from) at time zone 'UTC', to_timestamp(p_to) at time zone 'UTC', interval '1 day')::date loop
    perform private.ensure_day_partition('readings', d);
    perform private.ensure_day_partition('strings', d);
  end loop;
  create temp table _m on commit drop as
    select t, p, s,
           greatest(0, 5000 * sin(pi() * (((t + 7200) % 86400) - 21600) / 43200.0))::int + (random() * 50)::int as pv
      from generate_series(p_from - p_from % 60, p_to, 60) t,
           generate_series(p_lo, p_hi) p,
           unnest(array['A', 'B']) s;
  insert into public.readings (ts, sn, plant_id, status, device_time, pv_w, pv_today_kwh, pv_total_kwh,
      batt_power_w, batt_w, batt_soc, batt_voltage_v, batt_current_a, batt_temp_c,
      batt_chg_today_kwh, batt_dischg_today_kwh, grid_w, grid_import_today_kwh, grid_volt_v, grid_freq_hz,
      grid_relay_status, load_w, load_today_kwh, output_w, output_volt_v, output_freq_hz, carried)
  select t, 'LT' || p || s, p, 1, to_char(to_timestamp(t), 'YYYY-MM-DD HH24:MI:SS'), pv, 10 + random(), 5000 + random(),
         800 - pv / 3, 800 - pv / 3, 40 + 50 * random(), 52, -10, 25, 3, 4, 200, 2, 230, 50, 'ON',
         1200 + (random() * 300)::int, 15, 1100, 230, 50, false
    from _m
  on conflict do nothing;
  get diagnostics n = row_count;
  insert into public.strings (ts, sn, no, volt_v, current_a, power_w, today_kwh, plant_id)
  select t, 'LT' || p || s, no, 350, pv / 700.0, pv / 2, 5, p
    from _m, generate_series(1, 2) no
  on conflict do nothing;
  insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
  select p, t, sum(pv), 2400, 1600 - sum(pv) / 3, 400, 60, 'poller' from _m group by p, t
  on conflict do nothing;
  return n;
end $$;

-- Wall time in ms of each page reader for one plant, as its owner sees it.
-- Call inside: set role authenticated + request.jwt.claims for the owner.
create or replace function loadtest.time_pages(p_plant bigint)
returns jsonb language plpgsql as $$
declare t0 timestamptz; r jsonb := '{}';
begin
  t0 := clock_timestamp(); perform public.api_overview(p_plant);
  r := r || jsonb_build_object('overview', round(extract(epoch from clock_timestamp() - t0) * 1000));
  t0 := clock_timestamp(); perform public.api_balance(p_plant);
  r := r || jsonb_build_object('balance', round(extract(epoch from clock_timestamp() - t0) * 1000));
  t0 := clock_timestamp(); perform public.api_history(null, p_plant);
  r := r || jsonb_build_object('history', round(extract(epoch from clock_timestamp() - t0) * 1000));
  t0 := clock_timestamp(); perform public.api_energy('week', p_plant);
  r := r || jsonb_build_object('energy', round(extract(epoch from clock_timestamp() - t0) * 1000));
  t0 := clock_timestamp(); perform public.api_trends_daily(30, p_plant);
  r := r || jsonb_build_object('trends', round(extract(epoch from clock_timestamp() - t0) * 1000));
  return r;
end $$;
grant execute on function loadtest.time_pages(bigint) to authenticated;

-- Everything the test made.
create or replace function loadtest.cleanup()
returns void language plpgsql as $$
begin
  delete from public.readings where plant_id > 900000;
  delete from public.strings where plant_id > 900000;
  delete from public.agg_minute where plant_id > 900000;
  delete from private.meta where plant_id > 900000;
  delete from private.inverters where plant_id > 900000;
  delete from public.plant_config where plant_id > 900000;
  delete from public.plant_users where plant_id > 900000;
  delete from auth.users where email like '%@loadtest.invalid';
end $$;
