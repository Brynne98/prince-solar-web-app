CREATE OR REPLACE FUNCTION private.push_wanted(p_user uuid, p_switch text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select coalesce((select case p_switch
                            when 'grid' then p.grid when 'battery' then p.battery when 'panels' then p.panels
                            when 'readings' then p.readings when 'sunsynk' then p.sunsynk end
                     from public.push_prefs p where p.user_id = p_user), true)
$function$;
