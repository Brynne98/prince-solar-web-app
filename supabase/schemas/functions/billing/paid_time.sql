CREATE OR REPLACE FUNCTION billing.paid_time(p_tx jsonb, p_created timestamp with time zone, p_at timestamp with time zone)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare t timestamptz;
begin
  begin
    t := coalesce(p_tx->>'paid_at', p_tx->>'paidAt')::timestamptz;
  exception when others then
    t := null;
  end;
  if t is null or t > p_at or t < p_created - interval '5 minutes' then return p_at; end if;
  return t;
end $function$;
