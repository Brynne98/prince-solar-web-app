CREATE OR REPLACE FUNCTION private.grid_off_began(p_plant bigint, p_seen bigint)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with m as (select g.ts, g.present from private.grid_minutes(p_plant, p_seen - 43200, p_seen + 60) g),
  last_on as (select max(m.ts) ts from m where m.present and m.ts < p_seen)
  select min(m.ts) from m, last_on
   where not m.present and m.ts > last_on.ts and m.ts <= p_seen
  having min(m.ts) - max(last_on.ts) <= 180
$function$;
