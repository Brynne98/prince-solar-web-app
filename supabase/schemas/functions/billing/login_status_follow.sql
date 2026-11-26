CREATE OR REPLACE FUNCTION billing.login_status_follow()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  want text := case new.status when 'active' then 'ok' when 'needs_relink' then 'needs_reconnect' end;
  l billing.logins;
begin
  -- 'disabled' (disconnected in the old screens) is not a broken login: remove_login handles it
  if want is null then return null; end if;
  select * into l from billing.logins where id = new.id;
  if l.id is null or l.status = want then return null; end if;
  perform billing.lock_account(l.account);
  perform billing.lock_plants(array(select plant from billing.login_plants where login = l.id));
  update billing.logins set status = want where id = l.id and status <> want returning * into l;
  if l.id is not null then
    update billing.plants set version = version + 1
     where id in (select plant from billing.login_plants where login = l.id);
    perform billing.log_event(l.account, now(), 'poller', 'login_status',
                              jsonb_build_object('login', l.id, 'status', old.status),
                              jsonb_build_object('login', l.id, 'status', want));
  end if;
  return null;
end $function$;
