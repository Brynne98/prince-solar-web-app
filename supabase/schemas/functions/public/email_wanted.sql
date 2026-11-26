CREATE OR REPLACE FUNCTION public.email_wanted(p_user uuid, p_kind text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.email_prefs;
begin
  if p_kind not in ('weekly','monthly','yearly','grid','battery','panels','readings','sunsynk','reminders') then
    raise exception 'unknown email kind: %', p_kind;
  end if;
  select * into r from public.email_prefs where user_id = p_user;
  if not found then return true; end if;
  return case p_kind
    when 'weekly' then r.weekly     when 'monthly' then r.monthly   when 'yearly' then r.yearly
    when 'grid' then r.grid         when 'battery' then r.battery   when 'panels' then r.panels
    when 'readings' then r.readings when 'sunsynk' then r.sunsynk   when 'reminders' then r.reminders end;
end $function$;
