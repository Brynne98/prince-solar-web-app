CREATE OR REPLACE FUNCTION billing.add_period(p_from timestamp with time zone, p_interval text, p_billing_day integer, p_tz text)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  l timestamp := p_from at time zone p_tz;
  m date := (date_trunc('month', l) + case p_interval when 'year' then interval '1 year' else interval '1 month' end)::date;
  last_day int := extract(day from (m + interval '1 month - 1 day'))::int;
begin
  return ((m + (least(p_billing_day, last_day) - 1)) + l::time) at time zone p_tz;
end $function$;
