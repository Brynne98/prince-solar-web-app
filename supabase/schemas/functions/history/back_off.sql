CREATE OR REPLACE FUNCTION history.back_off(p_lane uuid, p_at timestamp with time zone)
 RETURNS integer
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into history.lanes as hl (lane, backoff_s, backoff_until) values (p_lane, 60, p_at + interval '60 seconds')
  on conflict (lane) do update set backoff_s = least(greatest(hl.backoff_s * 2, 60), 3600),
                                   backoff_until = p_at + make_interval(secs => least(greatest(hl.backoff_s * 2, 60), 3600))
  returning backoff_s
$function$;
