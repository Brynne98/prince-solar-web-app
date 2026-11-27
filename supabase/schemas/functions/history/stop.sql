CREATE OR REPLACE FUNCTION history.stop(p_plant bigint, p_reason text, p_at timestamp with time zone DEFAULT now())
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform history.stop_import(i.id, p_reason, p_at) from history.imports i where i.plant = p_plant and i.status = 'open';
  update history.days set status = 'dropped', note = p_reason, closed_at = p_at, claim = null, claimed_until = null
   where plant = p_plant and status = 'queued';
  delete from history.totals where plant = p_plant;
end $function$;
