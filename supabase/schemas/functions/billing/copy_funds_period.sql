CREATE OR REPLACE FUNCTION billing.copy_funds_period(p_kind text, p_due date, p_created date, p_billing_date date, p_paid timestamp with time zone, s billing.subscriptions)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce(case p_kind
    when 'renewal' then p_due::timestamp at time zone 'Africa/Johannesburg' = s.period_start
    when 'settle' then p_due::timestamp at time zone 'Africa/Johannesburg' = s.period_start
    -- the old run started the year on the day it settled the payment in Johannesburg (0212),
    -- not the day the card page opened: a page opened at 23:58 and paid at 00:02 starts the next day
    when 'start' then (p_paid at time zone 'Africa/Johannesburg')::date::timestamp at time zone 'Africa/Johannesburg' = s.period_start
    when 'switch' then p_billing_date::timestamp at time zone 'Africa/Johannesburg' = s.period_start
    when 'upgrade' then p_paid >= s.period_start and p_paid < s.period_end end, false)
$function$;
