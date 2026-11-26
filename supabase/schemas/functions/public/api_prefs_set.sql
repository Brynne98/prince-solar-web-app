CREATE OR REPLACE FUNCTION public.api_prefs_set(p_prefs jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'public', 'pg_temp'
AS $function$
  insert into public.profiles (user_id, prefs) values (auth.uid(), coalesce(p_prefs, '{}'::jsonb))
  on conflict (user_id) do update set prefs = public.profiles.prefs || excluded.prefs
  returning prefs
$function$;
