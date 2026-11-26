CREATE OR REPLACE FUNCTION public.link_attempt(p_user uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
begin
  -- One caller at a time per user, so two requests at once can't both get the 5th place.
  perform pg_advisory_xact_lock(hashtext('link_attempt:' || p_user::text));
  delete from private.link_attempts where at < now() - interval '1 hour';
  if (select count(*) from private.link_attempts where user_id = p_user) >= 5 then
    return false;
  end if;
  insert into private.link_attempts (user_id) values (p_user);
  return true;
end $function$;
