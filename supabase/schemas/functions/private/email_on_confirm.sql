CREATE OR REPLACE FUNCTION private.email_on_confirm()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.email_confirmed_at is not null and (tg_op = 'INSERT' or old.email_confirmed_at is null)
     and new.email is not null then
    insert into public.email_queue (user_id, kind, key, priority) values (new.id, 'welcome', 'welcome', 1)
    on conflict do nothing;
    insert into public.email_queue (user_id, kind, key, priority, due_at)
    values (new.id, 'need_a_hand', 'need_a_hand', 1, now() + interval '24 hours')
    on conflict do nothing;
    insert into public.email_queue (user_id, kind, key, priority, due_at)
    values (new.id, 'add_plant_reminder', 'add_plant_reminder', 1, now() + interval '7 days')
    on conflict do nothing;
  end if;
  return null;
end $function$;
