CREATE OR REPLACE FUNCTION public.billing_prorate(p_diff integer, p_today date, p_period_start date, p_next date)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when p_diff <= 0 then 0
    else round(p_diff::numeric
               * (p_next - greatest(least(p_today, p_next), p_period_start))
               / (p_next - p_period_start))::int end
$function$;
