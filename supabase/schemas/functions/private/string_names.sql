CREATE OR REPLACE FUNCTION private.string_names(p_nos integer[])
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case when cardinality(p_nos) = 1 then 'String ' || p_nos[1]
              else 'Strings ' || array_to_string(p_nos[1:cardinality(p_nos) - 1], ', ')
                   || ' and ' || p_nos[cardinality(p_nos)] end
$function$;
