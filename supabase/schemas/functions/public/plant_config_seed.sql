CREATE OR REPLACE FUNCTION public.plant_config_seed(p_rows jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- the brand's zone for the plant, when it gives a real one (R26); else the plant keeps its market's
  with z as (update plants.plants p set time_zone = r->>'timezone'
               from jsonb_array_elements(p_rows) r
              where p.id = (r->>'plant_id')::bigint and plants.tz_valid(nullif(r->>'timezone', ''))
                and p.time_zone is distinct from r->>'timezone' returning p.id)
  insert into public.plant_config (plant_id, currency, lat, lon, panel_azimuth, geometry_source)
  select (r->>'plant_id')::bigint,
         coalesce(nullif(upper(r->>'currency'), ''), 'ZAR'),
         nullif(r->>'lat', '')::double precision,
         nullif(r->>'lon', '')::double precision,
         case when nullif(r->>'lat', '')::double precision > 0 then 180 else 0 end,
         'default'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id) do nothing;
  -- the 60 days, for a plant that is read now (SOLAR-686 H8: History checks that); not paused
  select history.start((r->>'plant_id')::bigint, null, 'link')
    from jsonb_array_elements(p_rows) r
   where not coalesce((r->>'paused')::boolean, false)
$function$;
