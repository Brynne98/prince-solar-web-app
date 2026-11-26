CREATE OR REPLACE FUNCTION public.email_prefs_touch()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin new.updated_at := now(); return new; end $function$;
