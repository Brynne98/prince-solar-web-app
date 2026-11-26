CREATE OR REPLACE FUNCTION private.is_alert(p_kind text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select p_kind in ('grid_down', 'grid_back', 'batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back',
                    'string_dead', 'string_back', 'logger_stale', 'logger_back', 'sunsynk_down', 'sunsynk_back',
                    'needs_relink', 'relinked')
$function$;
