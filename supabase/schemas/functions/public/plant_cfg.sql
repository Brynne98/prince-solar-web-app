CREATE OR REPLACE FUNCTION public.plant_cfg(p_plant bigint)
 RETURNS TABLE(timezone text, currency text, lat double precision, lon double precision, system_kwp double precision, tariff_import double precision, battery_kwh double precision, battery_reserve_pct double precision, panel_tilt double precision, panel_azimuth double precision, geometry_source text, tariff_export double precision, battery_banks text, has_battery boolean, has_grid boolean, features_source text, batt_positive_means text, batt_sign_source text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select plants.tz(p_plant),
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
$function$;
