CREATE OR REPLACE FUNCTION history.renew(p_step text, p_id bigint, p_claim uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_step = 'totals' then
    update history.totals set claimed_until = p_at + interval '90 seconds'
     where plant = p_id and claim = p_claim and claimed_until > p_at;
  else
    update history.days set claimed_until = p_at + interval '90 seconds'
     where id = p_id and status = 'queued' and claim = p_claim and claimed_until > p_at;
  end if;
  return found;
end $function$;
