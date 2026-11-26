CREATE OR REPLACE FUNCTION private.setup_steps_left(p_user uuid, p_plant bigint)
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select case when coalesce((p.m->>'done')::boolean, false) then '{}'::text[] else private.setup_steps_open(p_plant) end
    from (select 1) one
    left join lateral (
      select pr.prefs->'firstSteps'->(p_plant::text) as m
        from public.profiles pr where pr.user_id = p_user) p on true
$function$;
