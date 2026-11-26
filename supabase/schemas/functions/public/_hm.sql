CREATE OR REPLACE FUNCTION public._hm(bkt integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  select lpad((bkt / 12)::text, 2, '0') || ':' || lpad(((bkt % 12) * 5)::text, 2, '0')
$function$;
