CREATE OR REPLACE FUNCTION private.name_list(p_names jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case when jsonb_array_length(p_names) <= 1 then p_names->>0
              else (select string_agg(n, ', ' order by o) from jsonb_array_elements_text(p_names) with ordinality e(n, o)
                     where o < jsonb_array_length(p_names))
                   || ' and ' || (p_names->>-1) end
$function$;
