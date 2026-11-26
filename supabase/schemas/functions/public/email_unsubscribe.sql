CREATE OR REPLACE FUNCTION public.email_unsubscribe(p_token uuid, p_kind text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_kind not in ('weekly','monthly','yearly','grid','battery','panels','readings','sunsynk','reminders') then
    return false;
  end if;
  update public.email_prefs set
    weekly    = weekly    and p_kind <> 'weekly',
    monthly   = monthly   and p_kind <> 'monthly',
    yearly    = yearly    and p_kind <> 'yearly',
    grid      = grid      and p_kind <> 'grid',
    battery   = battery   and p_kind <> 'battery',
    panels    = panels    and p_kind <> 'panels',
    readings  = readings  and p_kind <> 'readings',
    sunsynk   = sunsynk   and p_kind <> 'sunsynk',
    reminders = reminders and p_kind <> 'reminders'
  where unsub_token = p_token;
  return found;
end $function$;
