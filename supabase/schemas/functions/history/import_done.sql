CREATE OR REPLACE FUNCTION history.import_done()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.status = 'done' and old.status = 'open' then
    delete from public.email_queue q
     where q.plant_id = new.plant and q.kind = 'history' and q.status = 'skipped' and q.last_error = 'not read';
    perform private.email_enqueue_plant(new.plant, 'history', 'history:' || new.plant, '{}'::jsonb, null, 1::smallint);
  end if;
  return null;
end $function$;
