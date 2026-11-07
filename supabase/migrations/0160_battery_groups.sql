-- ============================================================================
-- 0160 — the battery's sizes, as panels keep theirs (SOLAR-401).
--
--   * plant_config.battery_groups: the owner's batteries as [{"count": 4, "kwh": 5.12}, ...],
--     null when the size was given as one total (or never given). Settings and First
--     steps write it together with battery_kwh. Without it a switch between Total and
--     By size at the same kWh saved nothing, and the battery always opened on Total.
--   * battery_groups_kwh(list): the list's total in kWh, or null for anything that is
--     not a non-empty list of whole counts 1-2000 and kWh above 0 up to 1000.
--   * A CHECK ties the two, as 0053 does for panels: a stored list is always valid and
--     battery_kwh is its total.
--   * log_config_change (0073) records it too.
-- ============================================================================

alter table public.plant_config add column if not exists battery_groups jsonb;

-- CASE, not AND/OR, so a cast only ever sees a JSON number (as panel_kwp, 0053)
create or replace function public.battery_groups_kwh(p_groups jsonb)
returns numeric
language sql immutable
set search_path = public, pg_temp
as $$
  select case
    when coalesce(jsonb_typeof(p_groups), '') <> 'array' then null
    when jsonb_array_length(p_groups) = 0 then null
    when exists (
      select 1 from jsonb_array_elements(p_groups) e
       where case when coalesce(jsonb_typeof(e -> 'count'), '') = 'number'
                   and coalesce(jsonb_typeof(e -> 'kwh'), '') = 'number'
                  then not ((e ->> 'count')::numeric between 1 and 2000 and (e ->> 'count')::numeric % 1 = 0
                        and (e ->> 'kwh')::numeric > 0 and (e ->> 'kwh')::numeric <= 1000)
                  else true end) then null
    else (select round(sum((e ->> 'count')::numeric * (e ->> 'kwh')::numeric), 3)
            from jsonb_array_elements(p_groups) e)
  end
$$;

-- The CHECK runs as whoever writes the row: Settings saves as the signed-in owner, and 0108
-- stopped new functions reaching authenticated by default (panel_kwp predates it)
grant execute on function public.battery_groups_kwh(jsonb) to authenticated;

alter table public.plant_config drop constraint if exists plant_config_battery_groups_check;
alter table public.plant_config add constraint plant_config_battery_groups_check
  check (battery_groups is null
         or coalesce(round(battery_kwh::numeric, 3) = public.battery_groups_kwh(battery_groups), false));

-- 0073's trigger with battery_groups added
drop trigger if exists log_config_change on public.plant_config;
create trigger log_config_change after insert or update on public.plant_config
  for each row execute function private.log_config_change(
    'tariff_import', 'tariff_export', 'currency', 'timezone', 'system_kwp', 'panel_groups',
    'battery_kwh', 'battery_groups', 'battery_reserve_pct', 'batt_positive_means', 'battery_banks');
