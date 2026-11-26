CREATE OR REPLACE FUNCTION billing.plan_ended_held(p_account uuid, p_sub text, p_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare h record;
begin
  if (select s.id::text from billing.subscriptions s where s.account = p_account order by started_at desc limit 1)
     is distinct from p_sub then return false; end if;
  select * into h from billing.renewal_hold(p_account, p_at);
  if h.in_flight then return true; end if;
  if h.bill is null or h.cutoff is null or p_at >= h.cutoff + interval '24 hours' then return false; end if;
  return exists (select 1 from billing.payment_attempts pa where pa.invoice = h.bill and pa.channel = 'card_page'
                    and pa.status in ('created', 'pending', 'unknown') and pa.created_at < h.cutoff);
end $function$;
