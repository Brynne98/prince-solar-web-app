CREATE OR REPLACE FUNCTION msg.route_event_rows()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into msg.outbox (event_id, channel, lane, kind, user_id, to_email, dedupe_key, not_before, expires_at)
  select new.id, k.channel, k.lane, new.kind, new.user_id,
         coalesce(new.to_email, (select u.email::text from auth.users u where u.id = new.user_id)),
         new.id || ':' || k.channel,
         case k.channel when 'email' then new.due_at else new.created_at end,
         case k.channel when 'email' then greatest(new.due_at, new.created_at) else new.created_at end + k.ttl
    from msg.kinds k
   where k.kind = new.kind and k.route = 'outbox'
     and ((k.channel = 'push' and new.push_skip = 'outbox') or (k.channel = 'email' and new.status = 'outbox'))
  on conflict (dedupe_key) do nothing;
  return null;
end $function$;
