CREATE OR REPLACE FUNCTION public.link_succeeded(p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
begin
  perform pg_advisory_xact_lock(hashtext('link_attempt:' || p_user::text));
  delete from private.link_attempts
  where ctid = (select ctid from private.link_attempts
                where user_id = p_user order by at desc limit 1);
end $function$;
