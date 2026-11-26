CREATE OR REPLACE FUNCTION public.soc_at(p_plant bigint, p_at bigint)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select round(a.soc)::int from public.agg_minute a
   where a.plant_id = p_plant and a.ts between p_at - 600 and p_at and a.soc is not null
   order by a.ts desc limit 1
$function$;
