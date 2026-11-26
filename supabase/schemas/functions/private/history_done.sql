CREATE OR REPLACE FUNCTION private.history_done(c plant_config)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select c.backfill_next is null
     and (c.temp_next is null or c.temp_next >= public.today_tz(plants.tz(c.plant_id)) - 1)
$function$;
