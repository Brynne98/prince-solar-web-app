CREATE OR REPLACE FUNCTION private.grid_notice_data(p_plant bigint, p_kind text, d jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case when p_kind in ('grid_down', 'grid_back') and p_plant is not null and d ? 'since'
    then coalesce((select (d - 'from') || jsonb_build_object('since', b.ts)
                     from (select private.grid_off_began(p_plant, (d->>'since')::bigint) ts) b
                    where b.ts is not null), d)
    else d end
$function$;
