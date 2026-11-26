CREATE OR REPLACE FUNCTION public.panel_kwp(p_groups jsonb)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select case
    when coalesce(jsonb_typeof(p_groups), '') <> 'array' then null
    when jsonb_array_length(p_groups) = 0 then null
    when exists (
      select 1 from jsonb_array_elements(p_groups) e
       where case when coalesce(jsonb_typeof(e -> 'count'), '') = 'number'
                   and coalesce(jsonb_typeof(e -> 'watts'), '') = 'number'
                  then not ((e ->> 'count')::numeric between 1 and 2000 and (e ->> 'count')::numeric % 1 = 0
                        and (e ->> 'watts')::numeric between 50 and 1000 and (e ->> 'watts')::numeric % 1 = 0)
                  else true end) then null
    else (select round(sum((e ->> 'count')::numeric * (e ->> 'watts')::numeric) / 1000, 3)
            from jsonb_array_elements(p_groups) e)
  end
$function$;
