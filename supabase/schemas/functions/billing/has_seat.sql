CREATE OR REPLACE FUNCTION billing.has_seat(p_account uuid, p_plant bigint, p_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from billing.seats s where s.account = p_account and s.plant = p_plant
                    and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at))
$function$;
