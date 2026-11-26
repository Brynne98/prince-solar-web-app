CREATE OR REPLACE FUNCTION billing.renewal_state(p_account uuid, p_at timestamp with time zone, st billing.status)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  tz text;
  h record;
  inv billing.invoices;
  pm billing.payment_methods;
  last_saved billing.payment_attempts;
  cur timestamptz;
  slot timestamptz;
  run_at timestamptz;
  next_on date;
  win_end timestamptz;
  reason text;
  refused billing.payment_methods;
begin
  -- the last saved card, when it was refused for good and nothing replaced it: still shown, never charged
  if (billing.active_method(p_account)).id is null then
    select * into refused from billing.payment_methods where account = p_account and reusable
     order by coalesce(activated_at, created_at) desc limit 1;
    if refused.disabled_reason is distinct from 'hard_decline' then refused := null; end if;
  end if;
  select coalesce(a.time_zone, m.default_time_zone) into tz
    from billing.accounts a join billing.markets m on m.code = a.market where a.id = p_account;
  select * into h from billing.renewal_hold(p_account, p_at);
  if st.state = 'past_due' then
    select * into inv from billing.invoices where subscription = st.sub and kind = 'renewal' and status = 'open'
     order by created_at desc limit 1;
  end if;

  if st.state = 'past_due' and inv.id is not null then
    pm := billing.active_method(p_account);
    if pm.id is not null then
      -- the retry day the job tries next: today's, if not tried since it began (as run_one counts), else the next one
      select max(x) into cur from (select st.past_due_since + make_interval(days => d) from unnest(st.retry_days) d) t (x)
       where x <= p_at;
      if cur is not null and not exists (select 1 from billing.payment_attempts pa where pa.invoice = inv.id
                                            and pa.status <> 'void' and pa.channel in ('saved_card', 'none')
                                            and pa.created_at >= cur) then
        slot := cur;
      else
        select min(x) into slot from (select st.past_due_since + make_interval(days => d) from unnest(st.retry_days) d) t (x)
         where x > p_at;
      end if;
      if slot is not null then
        run_at := billing.next_run_at(greatest(p_at, slot));
        if run_at < st.plan_ends_at then
          next_on := (run_at at time zone tz)::date;
          win_end := least(((run_at at time zone 'UTC')::date + time '06:00') at time zone 'UTC', st.plan_ends_at);
        end if;
      end if;
    end if;
    select * into last_saved from billing.payment_attempts where invoice = inv.id and channel = 'saved_card' and status <> 'void'
     order by created_at desc limit 1;
    reason := case
      when h.held_reference is not null
        or exists (select 1 from billing.payment_attempts pa where pa.invoice = inv.id and pa.channel = 'saved_card'
                      and pa.status in ('created', 'pending', 'unknown')) then 'checking'
      when pm.id is null then case when last_saved.status = 'failed' and last_saved.hard_decline then 'refused' else 'no_card' end
      when exists (select 1 from billing.payment_attempts pa where pa.invoice = inv.id and pa.channel = 'saved_card'
                      and pa.status = 'failed') then case when next_on is not null then 'retrying' else 'last_try_failed' end
    end;
  end if;

  return jsonb_build_object(
    'past_due_reason', reason,
    'next_try_on', next_on,
    'retry_window_ends_at', win_end,
    'renewal_in_flight', coalesce(h.in_flight, false),
    'held_reference', h.held_reference,
    'refused_card', case when refused.id is not null then jsonb_build_object(
                      'last4', refused.last4, 'exp_month', refused.exp_month, 'exp_year', refused.exp_year,
                      'card_type', refused.card_type) end,
    'due_bill', case when inv.id is not null then jsonb_build_object(
                  'id', inv.id, 'plan', inv.plan, 'plan_name', inv.plan_name, 'interval', inv.interval,
                  'amount_minor', inv.amount_minor, 'currency', inv.currency) end);
end $function$;
