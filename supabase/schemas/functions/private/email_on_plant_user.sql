CREATE OR REPLACE FUNCTION private.email_on_plant_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if exists (select 1 from public.plant_config c where c.plant_id = new.plant_id and private.history_done(c)) then
    insert into public.email_queue (user_id, plant_id, kind, key, priority)
    values (new.user_id, new.plant_id, 'history', 'history:' || new.plant_id, 1)
    on conflict do nothing;
  end if;
  return null;
end $function$;
