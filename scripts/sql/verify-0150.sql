-- verify-0150: one list of a plant's readings (SOLAR-255). Stop deletes every reading,
-- grid_off (once grid_cuts) included, and keeps settings, inverters and alert state.
-- Remove deletes all of it. Local stack only; one transaction, rolled back.
-- psql "$LOCAL_DB_URL" -X -q -f scripts/sql/verify-0150.sql   (exit code decides)
\set ON_ERROR_STOP 1
\o /dev/null
begin;

create function pg_temp.ok(cond boolean, what text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', what; end if;
  raise notice 'ok: %', what;
end $$;
create function pg_temp.readings() returns text[] language sql as $$
  select array['public.readings', 'public.strings', 'public.readings_5m', 'public.strings_5m',
    'public.agg_minute', 'public.agg_5m', 'public.plant_energy', 'public.inverter_history',
    'public.inverter_history_5m', 'public.grid_off', 'private.gaps', 'private.grid_off_progress',
    'private.free_trim_done'] $$;
create function pg_temp.kept() returns text[] language sql as $$
  select array['public.plant_config', 'public.config_changes', 'private.meta', 'private.inverters',
    'private.plant_alert_state', 'private.inverter_alert_state', 'private.string_alert_state'] $$;
create function pg_temp.n(t text, p bigint) returns bigint language plpgsql as $$
declare c bigint;
begin
  execute format('select count(*) from %s where plant_id = $1', t) into c using p;
  return c;
end $$;
-- tables still holding rows for p, out of ts
create function pg_temp.left(ts text[], p bigint) returns text language sql as $$
  select coalesce(string_agg(t, ', '), '') from unnest(ts) t where pg_temp.n(t, p) > 0 $$;

-- Two test plants with a row in every table, copied from any local plant. Triggers off
-- for the copy, so plant_row_guard lets rows in for plants nobody collects.
set local session_replication_role = replica;
do $$
declare t text; p bigint; src jsonb;
begin
  foreach t in array pg_temp.readings() || pg_temp.kept() loop
    execute format('select to_jsonb(x) from %s x limit 1', t) into src;
    -- empty here: a made-up row, a plain value in each required column
    if src is null then
      select jsonb_object_agg(column_name, case
               when data_type in ('smallint', 'integer', 'bigint', 'numeric', 'real', 'double precision') then to_jsonb(1)
               when data_type = 'boolean' then to_jsonb(false)
               when data_type like 'timestamp%' then to_jsonb(now())
               when data_type = 'date' then to_jsonb(current_date)
               when data_type in ('json', 'jsonb') then '{}'::jsonb
               else to_jsonb('x'::text) end)
        into src
        from information_schema.columns
       where table_schema || '.' || table_name = t and is_nullable = 'NO';
    end if;
    foreach p in array array[990501, 990502]::bigint[] loop
      execute format('insert into %s overriding system value select (jsonb_populate_record(null::%s, $1)).*', t, t)
        using src || jsonb_build_object('plant_id', p)
                  || case when src ? 'sn' then jsonb_build_object('sn', 'T' || p) else '{}' end
                  || case when jsonb_typeof(src->'id') = 'number' then jsonb_build_object('id', p) else '{}' end;
    end loop;
  end loop;
end $$;
set local session_replication_role = origin;

select pg_temp.ok(pg_temp.left(pg_temp.readings() || pg_temp.kept(), 990501) = array_to_string(pg_temp.readings() || pg_temp.kept(), ', '),
  'stop plant seeded in every table');
select pg_temp.ok(pg_temp.n('public.grid_off', 990502) = 1, 'remove plant seeded, grid_off included');

-- Stop: what the plant-wipe cron runs for each queued plant (nobody collects it).
insert into private.plant_wipe (plant_id) values (990501);
select pg_temp.ok(private.plant_wipe_readings(990501) = 11, 'stop counted a row in each of the 11 counted tables');
select pg_temp.ok(pg_temp.left(pg_temp.readings(), 990501) = '', 'stop left no readings (left: ' || pg_temp.left(pg_temp.readings(), 990501) || ')');
select pg_temp.ok(pg_temp.n('public.grid_off', 990501) = 0, 'stop deleted grid_off (was grid_cuts)');
select pg_temp.ok(pg_temp.left(pg_temp.kept(), 990501) = array_to_string(pg_temp.kept(), ', '), 'stop kept settings, inverters and alert state');
select pg_temp.ok(not exists (select 1 from private.plant_wipe where plant_id = 990501), 'stop took the plant off the wipe list');
select pg_temp.ok(pg_temp.n('public.readings', 990502) = 1, 'stop left the other plant alone');

-- Remove: what plant-purge runs once the last user unlinked it. A stop's wipe still queued goes too.
insert into private.plant_purge (plant_id) values (990502);
insert into private.plant_wipe (plant_id) values (990502);
select pg_temp.ok((private.purge_plant(990502)->>'grid_off')::int = 1, 'remove counts grid_off');
select pg_temp.ok(pg_temp.left(pg_temp.readings() || pg_temp.kept(), 990502) = '', 'remove left nothing (left: ' || pg_temp.left(pg_temp.readings() || pg_temp.kept(), 990502) || ')');
select pg_temp.ok(not exists (select 1 from private.plant_wipe where plant_id = 990502)
              and not exists (select 1 from private.plant_purge where plant_id = 990502), 'remove cleared both queues');

-- Started again before the wipe ran: everything stays.
insert into auth.users (id, email, email_confirmed_at, aud, role)
values ('00000000-0000-0000-0000-00000000c501', 'w1@example.test', now(), 'authenticated', 'authenticated');
insert into public.plant_users (plant_id, user_id, plant_name, linked_at)
values (990501, '00000000-0000-0000-0000-00000000c501', 'Restarted', now());
insert into public.readings select (jsonb_populate_record(null::public.readings, to_jsonb(x) || '{"plant_id": 990501, "sn": "T990501"}')).* from public.readings x where plant_id <> 990501 limit 1;
insert into private.plant_wipe (plant_id) values (990501);
select pg_temp.ok(private.plant_wipe_readings(990501) = 0 and pg_temp.n('public.readings', 990501) = 1, 'a plant collecting again keeps its readings');

rollback;
\o
\echo PASS verify-0150
