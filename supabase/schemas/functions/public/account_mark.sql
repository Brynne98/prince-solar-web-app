CREATE OR REPLACE FUNCTION public.account_mark(p_account uuid, p_status text, p_error text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
begin
  -- the copies' status moves only with a dead sign-in
  perform private.login_lock(array(select p_account union select private.login_copies(p_account)
                                    where p_status = 'needs_relink'), p_status);
  -- One row for the account poll was working on; its copies die with it below.
  insert into private.sunsynk_login_events (account_id, event, reason, last_ok_at, access_expires_at)
  select id, 'died', p_error, last_ok_at, access_expires_at
    from private.sunsynk_accounts
   where id = p_account and p_status = 'needs_relink';
  update private.sunsynk_accounts set status = p_status, last_error = p_error where id = p_account;
  -- A dead sign-in is dead for every copy holding that same refresh token. A copy
  -- with a different (newer) token, or a row with none, keeps its own status, and
  -- other errors stay with the row.
  update private.sunsynk_accounts set status = p_status, last_error = p_error
   where p_status = 'needs_relink' and id in (select private.login_copies(p_account))
     and public.account_refresh_get(id) = public.account_refresh_get(p_account);
end $function$;
