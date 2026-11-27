CREATE OR REPLACE FUNCTION public.login_throttled(p_login uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  update plants.logins set throttled_at = now() where id = p_login;
end $function$;
