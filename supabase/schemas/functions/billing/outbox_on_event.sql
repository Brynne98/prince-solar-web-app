CREATE OR REPLACE FUNCTION billing.outbox_on_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  -- (an interval switch that changes nothing logs no event: switch_interval returns first)
  if new.actor = 'owner' and new.kind in ('cancel', 'undo_cancel', 'downgrade', 'switch_interval') then
    perform billing.outbox_put(new.account,
      case when new.kind = 'undo_cancel'
             or (new.kind = 'downgrade' and new.after->>'plan' = new.before->>'plan'
                 and new.after->>'extras' = new.before->>'extras')
             -- back to the interval it has, a switch booked before: the switch is undone
             or (new.kind = 'switch_interval' and new.after->>'interval' = new.before->>'interval'
                 and new.after ? 'next_price' and new.after->>'next_price' is null
                 and new.before->>'next_price' is not null) then 'change_undone' else 'change_booked' end,
      null, new.id::text, 'event:' || new.id, new.at + interval '2 minutes', new.at + interval '2 days', new.at);
  end if;
  return null;
end $function$;
