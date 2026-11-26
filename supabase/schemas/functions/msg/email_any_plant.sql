CREATE OR REPLACE FUNCTION msg.email_any_plant(p_kind text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select p_kind in ('needs_relink', 'relinked', 'share_removed', 'plant_off_login') or p_kind like 'report\_%'
$function$;
