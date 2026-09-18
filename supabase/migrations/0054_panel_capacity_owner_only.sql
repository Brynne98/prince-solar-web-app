-- ============================================================================
-- 0054 — panel capacity comes from the owner, never from SunSynk.
--
-- SunSynk's plant totalPower is what was recorded at the first install, and it is
-- never revised. Checked 18 Sep 2026 on a real shared plant: SunSynk says 12 kW while
-- the plant's own log shows six strings whose bests add to 18.9 kW, panels having been
-- added in chunks months apart. A figure that wrong, presented as "N% of your 12 kW of
-- panels", is worse than no figure: the Solar tab now asks the owner to set it instead.
--
--   * plant_config_seed stops writing system_kwp (0045's body, one column dropped).
--   * plant_cfg stops falling back to app_config's SYSTEM_KWP for the calibration plant.
--     That was the deployment's own figure standing in for a row; with nothing seeded it
--     would leave one plant quoting 12.6 kW with an empty Settings row and no way to see
--     where the number came from. Calibration and the forecast read app_config directly
--     (0025, forecast/index.ts) and are untouched.
--   * The figures already seeded are cleared. A row with panel_groups was typed by its
--     owner and is left alone; the rest came from SunSynk or, for the first plant, from
--     app_config. `updated_by is null` is not a usable test of "the owner typed this":
--     both production rows carry an updated_by from unrelated saves (checked 18 Sep).
--     0053 shipped an hour before this, so the window for losing an owner-typed total is
--     that hour, and neither production row is one.
-- ============================================================================

create or replace function public.plant_config_seed(p_rows jsonb)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.plant_config (plant_id, timezone, currency, lat, lon, panel_azimuth, geometry_source,
                                   backfill_next, backfill_until, temp_next)
  select (r->>'plant_id')::bigint,
         tz,
         coalesce(nullif(upper(r->>'currency'), ''), 'ZAR'),
         nullif(r->>'lat', '')::double precision,
         nullif(r->>'lon', '')::double precision,
         case when nullif(r->>'lat', '')::double precision > 0 then 180 else 0 end,
         'default',
         (now() at time zone tz)::date - 60,
         (now() at time zone tz)::date - 14,
         (now() at time zone tz)::date - 60
    from jsonb_array_elements(p_rows) r,
         lateral (select coalesce(nullif(r->>'timezone', ''), 'Africa/Johannesburg') as tz) z
  on conflict (plant_id) do nothing
$$;

update public.plant_config set system_kwp = null
 where panel_groups is null and system_kwp is not null;

-- 0053's plant_cfg with the SYSTEM_KWP line dropped; every other line is unchanged.
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
         c.system_kwp,   -- the owner's figure or nothing; the Solar tab then asks for it
         coalesce(c.tariff_import, 0),
         -- app_config's pack size describes the deployment's own plant only; any
         -- other plant reads null until its owner sets it (the UI then asks).
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
