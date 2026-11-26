CREATE OR REPLACE FUNCTION private.email_on_history()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if private.history_done(new) and not private.history_done(old) then
    delete from public.email_queue q
     where q.plant_id = new.plant_id and q.kind = 'history' and q.status = 'skipped' and q.last_error = 'not read';
    perform private.email_enqueue_plant(new.plant_id, 'history', 'history:' || new.plant_id, '{}'::jsonb, null, 1::smallint);
  end if;
  return null;
end $function$;
