CREATE OR REPLACE FUNCTION public.api_trends_by_hour(p_days integer DEFAULT 14, p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object('days', p_days,
    'hours', coalesce((select jsonb_agg(to_jsonb(h) order by h.hour)
                         from public.q_by_hour(public.my_plant(p_plant), p_days) h), '[]'::jsonb))
$function$;
