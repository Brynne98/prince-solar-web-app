CREATE OR REPLACE FUNCTION private.plant_start_fill(p_plant bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare tz text;
begin
  -- After a wipe that is running now, never under it.
  perform pg_advisory_xact_lock(p_plant);
  delete from private.plant_wipe where plant_id = p_plant;
  if not exists (select 1 from public.plant_config where plant_id = p_plant) then
    -- Linked stopped, so never seeded (sunsynk.ts syncPlants). South Africa only;
    -- the seed sets the 60-day bookmarks.
    perform public.plant_config_seed(jsonb_build_array(jsonb_build_object('plant_id', p_plant)));
  else
    select coalesce(timezone, 'Africa/Johannesburg') into tz from public.plant_config where plant_id = p_plant;
    update public.plant_config
       set backfill_next = (now() at time zone tz)::date - 60,
           backfill_until = (now() at time zone tz)::date - 14,
           backfill_tries = 0,
           temp_next = (now() at time zone tz)::date - 60
     where plant_id = p_plant;
  end if;
  if p_plant not in (select public.live_plants()) then
    update public.plant_config set backfill_next = null, backfill_until = null, temp_next = null
     where plant_id = p_plant;
  end if;
  -- No readings counts from here (0174): the reading time kept from before the stop is old.
  insert into private.plant_alert_state (plant_id, started_at) values (p_plant, extract(epoch from now())::bigint)
  on conflict (plant_id) do update set started_at = excluded.started_at;
  perform public.plant_bootstrap_kick(p_plant);
end $function$;
