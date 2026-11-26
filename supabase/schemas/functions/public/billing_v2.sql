CREATE OR REPLACE FUNCTION public.billing_v2(p_cmd text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  acc uuid;
  uid uuid;
  plants bigint[];
  mk text;
  out jsonb;
begin
  if p_args ? 'user' then
    select id into acc from billing.accounts where user_id = (p_args->>'user')::uuid;
    if acc is null and p_cmd <> 'delete_account' then
      mk := coalesce(p_args->>'market', (select min(code) from billing.markets having count(*) = 1));
      if mk is null then raise exception 'which market?' using errcode = '22023'; end if;
      insert into billing.accounts (user_id, market) values ((p_args->>'user')::uuid, mk)
      on conflict (user_id) do nothing;
      select id into acc from billing.accounts where user_id = (p_args->>'user')::uuid;
    end if;
  end if;
  if jsonb_typeof(p_args->'plants') = 'array' then
    plants := array(select jsonb_array_elements_text(p_args->'plants')::bigint);
  end if;
  if p_cmd = 'apply_payment' then
    -- for the billing function's counts: the user id, and for a first plan whether it is a return
    out := billing.apply_payment(p_args->>'reference', p_args->'tx');
    select a.user_id, a.id into uid, acc from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
      join billing.accounts a on a.id = i.account where pa.reference = p_args->>'reference';
    if out->>'action' = 'applied' and out->>'kind' = 'purchase' then
      out := out || jsonb_build_object('days_since_plan',
        (select extract(day from now() - max(ended_at))::int from billing.subscriptions where account = acc and status = 'ended'));
    end if;
    return out || jsonb_build_object('user', uid);
  end if;
  return case p_cmd
    when 'account_state'    then billing.account_state(acc)
    when 'start_checkout'   then billing.start_checkout(acc, p_args->>'plan', p_args->>'interval', (p_args->>'extras')::int, plants)
    when 'upgrade'          then billing.upgrade(acc, p_args->>'plan', (p_args->>'extras')::int, plants, p_interval => p_args->>'interval')
    when 'downgrade'        then billing.downgrade(acc, p_args->>'plan', (p_args->>'extras')::int,
                                   array(select jsonb_array_elements_text(coalesce(p_args->'drop', '[]'))::bigint),
                                   p_interval => p_args->>'interval')
    when 'switch_interval'  then billing.switch_interval(acc, p_args->>'interval')
    when 'cancel'           then billing.cancel(acc)
    when 'undo_cancel'      then billing.undo_cancel(acc)
    when 'pay_now'          then billing.pay_now(acc)
    when 'start_card_check' then billing.start_card_check(acc)
    when 'delete_account'   then case when acc is null then jsonb_build_object('deleted', false) else billing.delete_account(acc) end
    when 'begin_attempt'    then billing.begin_attempt((p_args->>'invoice')::uuid, p_args->>'channel', now(), acc)
    when 'renewal_pages'    then billing.renewal_pages(acc)
    when 'verify_unanswered' then billing.verify_unanswered(p_args->>'reference')
    when 'attempt_page'     then coalesce(billing.attempt_page(p_args->>'reference', p_args->>'url'), '{}'::jsonb)
    when 'record_refund'    then billing.record_refund((p_args->>'refund')::uuid, p_args->>'error', p_args->>'provider_id')
    when 'record_refund_event' then billing.record_refund_event(p_args->>'reference', p_args->>'status', p_args->>'provider_id',
                                   (p_args->>'amount')::int, p_args->>'reason', now(), p_args->>'provider_ref')
    when 'record_dispute'   then billing.record_dispute(p_args->>'reference', p_args->>'event', p_args->>'status',
                                   (p_args->>'lost')::boolean, (p_args->>'amount')::int, now(), p_args->>'dispute_id')
    when 'event_begin'      then billing.event_begin(p_args->>'provider', p_args->>'type', p_args->>'entity', p_args->>'status', p_args->'payload')
    when 'event_done'       then (select '{}'::jsonb from (select billing.event_done((p_args->>'id')::bigint, p_args->>'error')) x)
    when 'run'              then billing.run()
    -- who opened the try, and the bill it pays (the paid message and its count)
    when 'attempt_user'     then (select jsonb_build_object('user', a.user_id, 'kind', i.kind, 'plan', i.plan,
                                   'plan_name', i.plan_name, 'interval', i.interval,
                                   'changed', i.kind = 'renewal' and i.plan is distinct from
                                     (select x.plan from billing.invoices x where x.subscription = i.subscription
                                         and x.status = 'paid' and x.kind in ('purchase', 'renewal', 'upgrade')
                                         and x.id <> i.id and x.period_start < i.period_start
                                       order by x.period_start desc, x.paid_at desc limit 1))
                                   from billing.payment_attempts pa
                                   join billing.invoices i on i.id = pa.invoice join billing.accounts a on a.id = i.account
                                  where pa.reference = p_args->>'reference')
  end;
end $function$;
