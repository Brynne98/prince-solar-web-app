CREATE OR REPLACE FUNCTION billing.grant_readings_start()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare t timestamptz := greatest(now(), new.starts_at);
begin
  if (new.ends_at is null or new.ends_at > t) and billing.reading_held(new.account, t) then
    perform billing.readings_resume(new.account, t);
  end if;
  return new;
end $function$;
