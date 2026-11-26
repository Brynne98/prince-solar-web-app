CREATE OR REPLACE FUNCTION private.alert_back_kind(p_kind text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case p_kind
    when 'grid_down' then 'grid_back' when 'logger_stale' then 'logger_back'
    when 'sunsynk_down' then 'sunsynk_back' when 'batt_hot' then 'batt_hot_back'
    when 'bank_drift' then 'bank_drift_back' when 'string_dead' then 'string_back'
    when 'needs_relink' then 'relinked' end
$function$;
