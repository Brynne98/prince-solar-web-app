CREATE OR REPLACE FUNCTION billing.renewal_hold(p_account uuid, p_at timestamp with time zone, OUT in_flight boolean, OUT held_reference text, OUT bill uuid, OUT cutoff timestamp with time zone)
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare s billing.subscriptions; inv billing.invoices;
begin
  in_flight := false;
  select * into s from billing.subscriptions where account = p_account and started_at <= p_at
   order by started_at desc limit 1;
  if s.id is null then return; end if;
  select * into inv from billing.invoices where subscription = s.id and kind = 'renewal' order by created_at desc limit 1;
  if inv.id is null or inv.status not in ('open', 'void') then return; end if;
  bill := inv.id;
  cutoff := billing.sub_cutoff(s.id);
  select pa.reference into held_reference from billing.payment_attempts pa
   where pa.invoice = inv.id and pa.channel = 'card_page' and pa.status in ('created', 'pending', 'unknown')
     and (pa.verified_processing or pa.verify_unanswered_at is not null)
     and (cutoff is null or (pa.created_at < cutoff and p_at < cutoff + interval '24 hours'))
   order by pa.created_at limit 1;
  in_flight := held_reference is not null
               or (exists (select 1 from billing.payment_attempts pa where pa.invoice = inv.id and pa.channel = 'saved_card'
                              and pa.status in ('created', 'pending', 'unknown'))
                   and (cutoff is null or p_at < cutoff + interval '24 hours'));
  if cutoff is null or p_at < cutoff then held_reference := null; end if;
end $function$;
