CREATE OR REPLACE FUNCTION history.lane_ok(p_lane uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update history.lanes set backoff_s = 0, backoff_until = null where lane = p_lane and backoff_s > 0
$function$;
