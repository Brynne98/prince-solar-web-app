CREATE OR REPLACE FUNCTION private.billing_keep_until()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  if new.plan <> 'free' then
    new.keep_until := null;
    new.ended_at := null;
  elsif old.plan in ('home', 'family') then
    new.ended_at := now();
    new.keep_until := null;
  end if;
  return new;
end $function$;
