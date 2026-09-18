-- ============================================================================
-- 0053 — panel capacity from Settings (PANEL_CAPACITY.md).
--
--   * plant_config.panel_groups: the owner's panels as [{"count": 28, "watts": 450}, ...],
--     null when capacity was given as one total (or never given). Settings writes it
--     together with system_kwp; nothing else writes either column after the link seed.
--   * panel_kwp(list): the list's total in kW, or null for anything that is not a
--     non-empty list of whole counts 1-2000 and whole watts 50-1000.
--   * A CHECK ties the two: a stored list is always valid and system_kwp is its total.
--     A CHECK and not a trigger: the service role updates this row too (recover's
--     watermarks, detection in 0041/0042), and a raise there would take recover down.
--   * plant_cfg: app_config's SYSTEM_KWP describes the deployment's own plant only, as
--     BATTERY_KWH already does; any other plant with no figure reads null, so the Solar
--     tab stops telling a stranger "of your 12.6 kW of panels".
-- ============================================================================

alter table public.plant_config add column if not exists panel_groups jsonb;

-- CASE, not AND/OR, so a cast only ever sees a JSON number: SQL does not promise to
-- evaluate a boolean's operands left to right. A missing key is a null jsonb_typeof,
-- hence the coalesce.
create or replace function public.panel_kwp(p_groups jsonb)
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
                   and coalesce(jsonb_typeof(e -> 'watts'), '') = 'number'
                  then not ((e ->> 'count')::numeric between 1 and 2000 and (e ->> 'count')::numeric % 1 = 0
                        and (e ->> 'watts')::numeric between 50 and 1000 and (e ->> 'watts')::numeric % 1 = 0)
                  else true end) then null
    else (select round(sum((e ->> 'count')::numeric * (e ->> 'watts')::numeric) / 1000, 3)
            from jsonb_array_elements(p_groups) e)
  end
$$;

-- coalesce(..., false): a CHECK passes on null, and an invalid list or a null total
-- makes the comparison null
alter table public.plant_config drop constraint if exists plant_config_panel_groups_check;
alter table public.plant_config add constraint plant_config_panel_groups_check
  check (panel_groups is null
         or coalesce(round(system_kwp::numeric, 3) = public.panel_kwp(panel_groups), false));

-- 0042's plant_cfg with only the system_kwp line changed
create or replace function public.plant_cfg(p_plant bigint)
returns table (timezone text, currency text, lat double precision, lon double precision,
               system_kwp double precision, tariff_import double precision,
               battery_kwh double precision, battery_reserve_pct double precision,
               panel_tilt double precision, panel_azimuth double precision, geometry_source text,
               tariff_export double precision, battery_banks text, has_battery boolean, has_grid boolean,
               features_source text, batt_positive_means text, batt_sign_source text)
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce(c.timezone, 'Africa/Johannesburg'),
         coalesce(c.currency, 'ZAR'),
         coalesce(c.lat, public.cfg('LAT')), coalesce(c.lon, public.cfg('LON')),
         -- app_config's panel size and pack size describe the deployment's own plant
         -- only; any other plant reads null until its owner sets them.
         coalesce(c.system_kwp, case when x.id = public.calibration_plant() then public.cfg('SYSTEM_KWP') end),
         coalesce(c.tariff_import, 0),
         coalesce(c.battery_kwh, case when x.id = public.calibration_plant() then public.cfg('BATTERY_KWH') end),
         coalesce(c.battery_reserve_pct, public.cfg('BATTERY_RESERVE_PCT'), 20),
         coalesce(c.panel_tilt, public.cfg('PANEL_TILT'), 15),
         coalesce(c.panel_azimuth, public.cfg('PANEL_AZIMUTH'), 0),
         coalesce(c.geometry_source, 'default'),
         coalesce(c.tariff_export, 0),
         coalesce(c.battery_banks, 'per-inverter'),
         c.has_battery, c.has_grid,
         coalesce(c.features_source, 'default'),
         c.batt_positive_means, coalesce(c.batt_sign_source, 'default')
    from (select p_plant as id) x
    left join public.plant_config c on c.plant_id = x.id
$$;
