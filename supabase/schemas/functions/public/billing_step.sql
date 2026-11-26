CREATE OR REPLACE FUNCTION public.billing_step(p_date date, p_period text, p_day integer, p_steps integer)
 RETURNS date
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select (m + (least(p_day, extract(day from m + interval '1 month' - interval '1 day')::int) - 1)
              * interval '1 day')::date
    from (select date_trunc('month', p_date)
                 + p_steps * case p_period when 'yearly' then interval '1 year' else interval '1 month' end
                 as m) s
$function$;
