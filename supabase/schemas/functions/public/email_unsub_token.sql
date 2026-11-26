CREATE OR REPLACE FUNCTION public.email_unsub_token(p_user uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.email_prefs (user_id) values (p_user) on conflict (user_id) do nothing;
  return (select unsub_token from public.email_prefs where user_id = p_user);
end $function$;
