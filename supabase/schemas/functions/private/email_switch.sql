CREATE OR REPLACE FUNCTION private.email_switch(p_kind text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when p_kind in ('grid_down', 'grid_back') then 'grid'
    when p_kind in ('batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back') then 'battery'
    when p_kind in ('string_dead', 'string_back') then 'panels'
    when p_kind in ('logger_stale', 'logger_back') then 'readings'
    when p_kind in ('sunsynk_down', 'sunsynk_back') then 'sunsynk'
    when p_kind = 'report_week' then 'weekly'
    when p_kind = 'report_month' then 'monthly'
    when p_kind = 'report_year' then 'yearly'
    when p_kind in ('unpaid_reminder', 'unpaid_last', 'unpaid_deleted', 'free_week_soon', 'winback') then 'reminders'
  end
$function$;
