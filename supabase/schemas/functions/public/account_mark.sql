CREATE OR REPLACE FUNCTION public.account_mark(p_account uuid, p_status text, p_error text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
begin
  -- the words before SOLAR-681 R4, from a poll function deployed before this database
  p_status := case p_status when 'active' then 'ok' when 'needs_relink' then 'needs_reconnect' else p_status end;
  -- the copies' status moves only with a dead sign-in
  perform private.login_lock(array(select p_account union select private.login_copies(p_account)
                                    where p_status = 'needs_reconnect'), p_status);
  -- One row for the account poll was working on; its copies die with it below.
  insert into plants.login_events (account_id, event, reason, last_ok_at, access_expires_at)
  select id, 'died', p_error, last_ok_at, access_expires_at
    from plants.logins
   where id = p_account and p_status = 'needs_reconnect';
  update plants.logins set status = p_status, last_error = p_error where id = p_account;
  -- A dead sign-in is dead for every copy holding that same refresh token. A copy
  -- with a different (newer) token, or a row with none, keeps its own status, and
  -- other errors stay with the row.
  update plants.logins set status = p_status, last_error = p_error
   where p_status = 'needs_reconnect' and id in (select private.login_copies(p_account))
     and public.account_refresh_get(id) = public.account_refresh_get(p_account);
end $function$;
