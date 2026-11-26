CREATE OR REPLACE FUNCTION private.alert_group(p_kind text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select coalesce(private.email_switch(p_kind), case when p_kind in ('needs_relink', 'relinked') then 'sunsynk' end)
$function$;
