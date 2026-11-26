CREATE OR REPLACE FUNCTION msg.email_settled()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.status = 'sent' then
    update public.email_queue q set sent_at = now() where q.id = new.event_id;
  end if;
  -- history not sent because the plant isn't read: marked as email_claim did, so
  -- email_on_history (0217) clears it and queues it again when the history finishes again
  if new.kind = 'history' and new.status = 'dropped' and new.drop_reason in ('plant not live', 'plant not chosen') then
    update public.email_queue q set status = 'skipped', last_error = 'not read' where q.id = new.event_id;
  end if;
  if new.kind = 'feedback' then
    -- the message stays in private.feedback; its copy and the screenshot go (0179)
    update public.email_queue q set data = jsonb_build_object('id', q.data->'id') where q.id = new.event_id;
  elsif new.kind = 'account_deleted' then
    -- the person is gone: so is the address (email_done). Takes this outbox row with it.
    delete from public.email_queue q where q.id = new.event_id;
  end if;
  return null;
end $function$;
