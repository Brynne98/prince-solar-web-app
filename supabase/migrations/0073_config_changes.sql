-- ============================================================================
-- 0073 — a dated log of plant settings and inverter details (SOLAR-66).
--
-- plant_config (tariffs, panels, battery) and private.meta (model, firmware,
-- battery packs) hold the current value only. After a tariff change past
-- savings cannot be worked out again, panels added in chunks leave no trace,
-- and a warranty claim has no dates. Triggers now append every change of the
-- listed fields to public.config_changes; nothing else is touched, so the app,
-- the poller and recover need no deploy.
--
-- Logged: plant_config tariff_import, tariff_export, currency, timezone,
-- system_kwp, panel_groups, battery_kwh, battery_reserve_pct,
-- batt_positive_means, battery_banks; meta model, soft_ver, hmi_ver,
-- capacity_ah, number_of_batteries. Not logged: watermarks and bookkeeping,
-- has_grid (flips with every switch-off; grid_off covers it), meta status and
-- alias. The migration records today's values as each row's first entry.
-- Nothing reads the log yet; owners can read their own plant's rows.
-- ============================================================================

create table if not exists public.config_changes (
  id          bigint generated always as identity primary key,
  plant_id    bigint      not null,
  sn          text,                          -- inverter, for meta fields
  field       text        not null,
  old_value   jsonb,                         -- null for a first entry
  new_value   jsonb,
  changed_at  timestamptz not null default now(),
  changed_by  uuid                           -- the signed-in user, null for the system
);
create index if not exists config_changes_plant on public.config_changes (plant_id, changed_at);
comment on table public.config_changes is
  'Append-only log of plant settings and inverter details: field, old and new value, when, who. Written by triggers on plant_config and private.meta (SOLAR-66).';

alter table public.config_changes enable row level security;
drop policy if exists config_changes_read on public.config_changes;
create policy config_changes_read on public.config_changes for select to authenticated
  using (plant_id in (select public.my_plant_ids()));

-- One trigger function for both tables; the fields to log are the trigger's arguments.
create or replace function private.log_config_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  f text;
  o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  n jsonb := to_jsonb(new);
begin
  if new.plant_id is null then return new; end if;
  foreach f in array tg_argv loop
    if (o -> f) is distinct from (n -> f) and not (tg_op = 'INSERT' and n -> f = 'null'::jsonb) then
      insert into public.config_changes (plant_id, sn, field, old_value, new_value, changed_by)
      values (new.plant_id,
              case when tg_table_name = 'meta' then n ->> 'sn' end,
              f,
              nullif(o -> f, 'null'::jsonb),
              nullif(n -> f, 'null'::jsonb),
              auth.uid());
    end if;
  end loop;
  return new;
end $$;
revoke all on function private.log_config_change() from public, anon, authenticated;

drop trigger if exists log_config_change on public.plant_config;
create trigger log_config_change after insert or update on public.plant_config
  for each row execute function private.log_config_change(
    'tariff_import', 'tariff_export', 'currency', 'timezone', 'system_kwp', 'panel_groups',
    'battery_kwh', 'battery_reserve_pct', 'batt_positive_means', 'battery_banks');

drop trigger if exists log_config_change on private.meta;
create trigger log_config_change after insert or update on private.meta
  for each row execute function private.log_config_change(
    'model', 'soft_ver', 'hmi_ver', 'capacity_ah', 'number_of_batteries');

-- ── purge: 0072's body plus the new table ───────────────────────────────────
create or replace function private.purge_plant(p_plant bigint, p_wait boolean default true)
returns jsonb
language plpgsql
set search_path = public, private, pg_temp
as $$
declare
  out jsonb := '{}'::jsonb;
  n bigint;
begin
  if p_wait then
    perform pg_advisory_xact_lock(p_plant);
  elsif not pg_try_advisory_xact_lock(p_plant) then
    return null;
  end if;
  if not exists (select 1 from private.plant_purge where plant_id = p_plant) then
    return null;
  end if;
  if exists (select 1 from public.plant_users where plant_id = p_plant) then
    delete from private.plant_purge where plant_id = p_plant;
    return jsonb_build_object('skipped', 'linked again');
  end if;

  delete from public.readings            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings', n);
  delete from public.strings             where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings', n);
  delete from public.readings_5m         where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings_5m', n);
  delete from public.strings_5m          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings_5m', n);
  delete from public.agg_minute          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_minute', n);
  delete from public.agg_5m              where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_5m', n);
  delete from public.plant_energy        where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_energy', n);
  delete from public.inverter_history    where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history', n);
  delete from public.inverter_history_5m where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history_5m', n);
  delete from public.grid_off            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('grid_off', n);
  delete from public.plant_config        where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from public.config_changes      where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('config_changes', n);
  delete from private.gaps               where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('gaps', n);
  delete from private.meta               where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  delete from private.grid_off_progress  where plant_id = p_plant;
  delete from private.plant_purge        where plant_id = p_plant;
  return out;
end $$;

-- ── today's values as the first entry ───────────────────────────────────────
insert into public.config_changes (plant_id, sn, field, old_value, new_value)
select c.plant_id, null, f.key, null, f.value
  from public.plant_config c,
       jsonb_each(to_jsonb(c)) f
 where f.key in ('tariff_import', 'tariff_export', 'currency', 'timezone', 'system_kwp', 'panel_groups',
                 'battery_kwh', 'battery_reserve_pct', 'batt_positive_means', 'battery_banks')
   and f.value <> 'null'::jsonb
   and not exists (select 1 from public.config_changes x where x.plant_id = c.plant_id and x.sn is null and x.field = f.key);

insert into public.config_changes (plant_id, sn, field, old_value, new_value)
select m.plant_id, m.sn, f.key, null, f.value
  from private.meta m,
       jsonb_each(to_jsonb(m)) f
 where m.plant_id is not null
   and f.key in ('model', 'soft_ver', 'hmi_ver', 'capacity_ah', 'number_of_batteries')
   and f.value <> 'null'::jsonb
   and not exists (select 1 from public.config_changes x where x.plant_id = m.plant_id and x.sn = m.sn and x.field = f.key);
