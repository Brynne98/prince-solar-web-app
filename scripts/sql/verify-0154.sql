-- verify-0154: the shorter alert words (SOLAR-354). Local stack only; one transaction,
-- rolled back. Run after 0154 is applied (or after \i of it inside the same session).
-- psql "$LOCAL_DB_URL" -X -q -f scripts/sql/verify-0154.sql   (exit code decides)
\set ON_ERROR_STOP 1
begin;

create function pg_temp.ok(cond boolean, what text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', what; end if;
  raise notice 'ok: %', what;
end $$;
-- title · body for one kind; 17:42 SAST on 2025-10-28 is 1761666120
create function pg_temp.w(k text, d jsonb) returns text language sql as $$
  select (t->>'title') || ' · ' || (t->>'body')
    from private.alert_text(k, d, to_timestamp(1761672000), 'Africa/Johannesburg') t $$;

select pg_temp.ok(pg_temp.w('grid_down', '{"since":1761666120,"chargePct":62}') = 'Grid down · Off since 17:42. Battery 62%.', 'grid down');
select pg_temp.ok(pg_temp.w('grid_down', '{"since":1761666120}') = 'Grid down · Off since 17:42.', 'grid down, no charge');
select pg_temp.ok(pg_temp.w('grid_back', '{"since":1761666120,"at":1761671700}') = 'Grid back · Back after 1h 33m.', 'grid back');
select pg_temp.ok(pg_temp.w('batt_hot', '{"at":1761666120,"tempC":47}') = 'Battery hot · 47 °C at 17:42.', 'battery hot');
select pg_temp.ok(pg_temp.w('batt_hot_back', '{"since":1761666120,"at":1761671700,"tempC":42}') = 'Battery cooled · 42 °C. Hot for 1h 33m.', 'battery cooled');
select pg_temp.ok(pg_temp.w('bank_drift', '{"banks":[{"name":"Master","chargePct":72},{"name":"Slave","chargePct":60}]}') = 'Batteries charging unevenly · Master 72%, Slave 60%.', 'uneven');
select pg_temp.ok(pg_temp.w('bank_drift_back', '{"since":1761666120,"at":1761671700,"banks":[{"name":"Master","chargePct":70},{"name":"Slave","chargePct":68}]}') = 'Batteries charging evenly · Master 70%, Slave 68%. Apart for 1h 33m.', 'even');
select pg_temp.ok(pg_temp.w('string_dead', '{"since":1761666120,"inverter":"Slave","string":"String 3"}') = 'Panels stopped producing · Slave, string 3, since 17:42.', 'string dead');
select pg_temp.ok(pg_temp.w('string_back', '{"since":1761666120,"at":1761671700,"inverter":"Slave","string":"String 3"}') = 'Panels producing again · Slave, string 3. Stopped for 1h 33m.', 'string back');
select pg_temp.ok(pg_temp.w('logger_stale', '{"since":1761666120}') = 'No readings · Last reading 17:42.', 'no readings');
select pg_temp.ok(pg_temp.w('logger_stale', '{"since":1761666120,"inverter":"Slave"}') = 'No readings from Slave · Last reading 17:42.', 'one inverter quiet');
select pg_temp.ok(pg_temp.w('logger_back', '{"since":1761666120,"at":1761671700}') = 'Readings back · Back after 1h 33m.', 'readings back');
select pg_temp.ok(pg_temp.w('sunsynk_down', '{"since":1761666120}') = 'SunSynk is down · Since 17:42.', 'sunsynk down');
select pg_temp.ok(pg_temp.w('sunsynk_back', '{"since":1761666120,"at":1761671700}') = 'SunSynk is back · Back after 1h 33m.', 'sunsynk back');

rollback;
