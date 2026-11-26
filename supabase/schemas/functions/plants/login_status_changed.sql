CREATE OR REPLACE FUNCTION plants.login_status_changed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.status is not distinct from old.status then return null; end if;
  perform plants.bump(array(select lp.plant from plants.login_plants lp where lp.login = new.id));
  if new.account is not null then
    perform billing.log_event(new.account, now(), 'poller', 'login_status',
                              jsonb_build_object('login', new.id, 'status', old.status),
                              jsonb_build_object('login', new.id, 'status', new.status));
  end if;
  return null;
end $function$;
