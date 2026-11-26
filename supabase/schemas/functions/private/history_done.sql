CREATE OR REPLACE FUNCTION private.history_done(c plant_config)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select c.backfill_next is null
     and (c.temp_next is null or c.temp_next >= public.today_tz(coalesce(c.timezone, 'Africa/Johannesburg')) - 1)
$function$;
