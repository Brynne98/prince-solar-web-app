CREATE OR REPLACE FUNCTION private.grid_off_start(p_plant bigint, p_seen bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with b as (select private.grid_off_began(p_plant, p_seen) ts),
  last_on as (select max(g.ts) ts from private.grid_minutes(p_plant, p_seen - 43200, p_seen) g where g.present)
  select case
    when b.ts is not null then jsonb_build_object('since', b.ts)
    when last_on.ts is null then jsonb_build_object('since', p_seen)
    else jsonb_build_object('since', p_seen, 'from', last_on.ts) end
    from b, last_on
$function$;
