CREATE OR REPLACE FUNCTION billing.upgrade_due(s billing.subscriptions, m billing.markets, p_new_amt integer, p_interval text, p_at timestamp with time zone)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  with d as (
    select (s.period_end at time zone m.default_time_zone)::date - (s.period_start at time zone m.default_time_zone)::date as days_all,
           (s.period_end at time zone m.default_time_zone)::date - (p_at at time zone m.default_time_zone)::date as days_to_end,
           s.amount_minor + s.extra_places * s.extra_place_minor as old_amt
  ), l as (
    -- a paid year copied from the old billing starts on its billing date, maybe still ahead:
    -- the days left are that year's
    -- (past the end, as a quote may be asked: none left, review Neon)
    select days_all, greatest(least(days_to_end, days_all), 0) as days_left, old_amt from d
  )
  select greatest(case when p_interval = s.interval
                       then round((p_new_amt - old_amt)::numeric * days_left / greatest(days_all, 1))
                       else p_new_amt - round(old_amt::numeric * days_left / greatest(days_all, 1)) end, 0)::int
    from l
$function$;
