CREATE OR REPLACE FUNCTION public.billing_plant_limit(p_plan text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case p_plan when 'family' then null else 1 end
$function$;
