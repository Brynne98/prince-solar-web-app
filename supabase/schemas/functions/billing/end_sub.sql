CREATE OR REPLACE FUNCTION billing.end_sub(p_sub uuid, p_ended_at timestamp with time zone, p_reason text, p_at timestamp with time zone, p_actor text, p_bump boolean DEFAULT true)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare s billing.subscriptions;
begin
  update billing.subscriptions set status = 'ended', ended_at = p_ended_at, past_due_since = null, version = version + 1
   where id = p_sub and status in ('active', 'past_due') returning * into s;
  if not found then return; end if;
  update billing.invoices set status = 'void' where subscription = p_sub and status = 'open';
  if p_bump then perform billing.bump(s.account); end if;
  perform billing.log_event(s.account, p_at, p_actor, 'plan_ended', null,
                            jsonb_build_object('sub', p_sub, 'ended_at', p_ended_at), p_reason);
end $function$;
