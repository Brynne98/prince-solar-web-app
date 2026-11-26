CREATE OR REPLACE FUNCTION public.plant_config_seed(p_rows jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  insert into public.plant_config (plant_id, timezone, currency, lat, lon, panel_azimuth, geometry_source,
                                   backfill_next, backfill_until, temp_next)
  select (r->>'plant_id')::bigint,
         tz,
         coalesce(nullif(upper(r->>'currency'), ''), 'ZAR'),
         nullif(r->>'lat', '')::double precision,
         nullif(r->>'lon', '')::double precision,
         case when nullif(r->>'lat', '')::double precision > 0 then 180 else 0 end,
         'default',
         case when not paused then (now() at time zone tz)::date - 60 end,
         case when not paused then (now() at time zone tz)::date - 14 end,
         case when not paused then (now() at time zone tz)::date - 60 end
    from jsonb_array_elements(p_rows) r,
         lateral (select coalesce(nullif(r->>'timezone', ''), 'Africa/Johannesburg') as tz,
                         coalesce((r->>'paused')::boolean, false) as paused) z
  on conflict (plant_id) do nothing
$function$;
