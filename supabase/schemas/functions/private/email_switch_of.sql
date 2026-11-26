CREATE OR REPLACE FUNCTION private.email_switch_of(p_kind text, p_data jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when p_kind = 'report_week' and p_data->>'freeWeekEnds' = 'true' then 'reminders'
              else private.email_switch(p_kind) end
$function$;
