CREATE OR REPLACE FUNCTION billing.event_begin(p_provider text, p_type text, p_entity text, p_status text, p_payload jsonb, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare e billing.payment_events;
begin
  -- on hold for the way back: refused, so the billing function answers 500 and Paystack sends
  -- the notice again later (to whichever billing is live then)
  lock table billing.payments_pause in share mode;
  if exists (select 1 from billing.payments_pause) then
    raise exception 'payments are on hold for an update' using errcode = '55000';
  end if;
  insert into billing.payment_events (provider, event_type, entity_id, status, payload, received_at)
  values (p_provider, p_type, p_entity, coalesce(p_status, ''), p_payload, p_at)
  on conflict (provider, event_type, entity_id, status) do update set tries = payment_events.tries + 1
  returning * into e;
  return jsonb_build_object('id', e.id, 'process', e.processed_at is null);
end $function$;
