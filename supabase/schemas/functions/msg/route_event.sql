CREATE OR REPLACE FUNCTION msg.route_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.user_id is not null and new.pushed_at is null and private.is_alert(new.kind)
     and exists (select 1 from msg.kinds k where k.kind = new.kind and k.channel = 'push' and k.route = 'outbox') then
    new.pushed_at := now();
    new.push_skip := case when new.status = 'queued' then 'outbox'
                          when new.status = 'skipped' and new.last_error = 'one email per login' then 'one per login'
                          else 'not queued' end;
  end if;
  if new.status = 'queued'
     and exists (select 1 from msg.kinds k where k.kind = new.kind and k.channel = 'email' and k.route = 'outbox') then
    new.status := 'outbox';
  end if;
  return new;
end $function$;
