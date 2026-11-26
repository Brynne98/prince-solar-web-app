CREATE OR REPLACE FUNCTION plants.brand_for_username(p_username text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select case when lower(p_username) like '%@mock' then 'mock' else plants.default_brand() end
$function$;
