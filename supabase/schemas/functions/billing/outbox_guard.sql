CREATE OR REPLACE FUNCTION billing.outbox_guard(o billing.outbox, p_at timestamp with time zone)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  st billing.status;
  inv billing.invoices;
  att billing.payment_attempts;
  ev billing.account_events;
  ms jsonb;
  u uuid;
  pm billing.payment_methods;
begin
  if o.account is null then return 'no account'; end if;
  if o.expires_at is not null and o.expires_at <= p_at then return 'expired'; end if;
  select user_id into u from billing.accounts where id = o.account;
  if u is null then return 'no account'; end if;
  if (select reminder from billing.outbox_kinds where key = o.key) and not public.email_wanted(u, 'reminders') then
    return 'reminders off';
  end if;
  st := billing.account_status(o.account, p_at);
  if o.invoice is not null then select * into inv from billing.invoices where id = o.invoice; end if;
  case o.key
    when 'receipt' then
      if inv.status is distinct from 'paid' then return 'bill not paid'; end if;
    when 'payment_failed' then
      if inv.status is distinct from 'open' then return 'bill settled'; end if;
      if st.state <> 'past_due' then return 'not past due'; end if;
      if st.plan_ends_at <= p_at then return 'past the pay-by date'; end if;
      -- a later try on the same bill has its own email
      if exists (select 1 from billing.payment_attempts pa where pa.invoice = inv.id and pa.status = 'failed'
                    and pa.channel in ('saved_card', 'none')
                    and pa.created_at > (select created_at from billing.payment_attempts where id = o.ref::uuid)) then
        return 'a later try';
      end if;
    when 'card_update', 'payment_due' then
      if inv.status is distinct from 'open' then return 'bill settled'; end if;
      if (billing.active_method(o.account)).id is not null then return 'card replaced'; end if;
      if st.state <> 'past_due' then return 'not past due'; end if;
      if st.plan_ends_at <= p_at then return 'past the pay-by date'; end if;
    when 'payment_reminder' then                                                  -- 0276
      return (billing.payment_reminder_check(o.account, o.invoice, p_at)).stop;
    when 'refund' then
      if not exists (select 1 from billing.refunds r where r.id = o.ref::uuid and r.status = 'processed') then
        return 'refund not processed';
      end if;
    when 'plan_ended' then
      if st.state <> 'ended' then return 'plan running again'; end if;
      if (select s.id from billing.subscriptions s where s.account = o.account order by started_at desc limit 1)
         is distinct from o.ref::uuid then return 'a later plan'; end if;
      if o.ended_at is not null
         and (select s.ended_at from billing.subscriptions s where s.id = o.ref::uuid) is distinct from o.ended_at then
        return 'ending no longer current';
      end if;
    when 'change_booked', 'change_undone' then
      select * into ev from billing.account_events where id = o.ref::bigint;
      if exists (select 1 from billing.account_events e where e.account = o.account and e.id > ev.id and e.actor = 'owner'
                    and e.kind in ('cancel', 'undo_cancel', 'downgrade', 'switch_interval')) then
        return 'changed again';
      end if;
      if st.state <> 'active' or st.sub is null then return 'plan not running'; end if;
      ms := billing.money_state(o.account, p_at, st.state);
      if ev.kind = 'cancel' and st.cancel_at is null then return 'cancel undone'; end if;
      if ev.kind = 'undo_cancel' and st.cancel_at is not null then return 'cancelled again'; end if;
      if o.key = 'change_booked' and ev.kind = 'downgrade' and ms->>'next_plan' is distinct from ev.after->>'plan' then
        return 'downgrade changed';
      end if;
      if ev.kind = 'switch_interval' and ms->>'next_interval' is distinct from ev.after->>'interval' then
        return 'interval changed';
      end if;
    when 'card_changed' then
      -- the same card, made active at the time this row was queued for (dedupe_key's last part):
      -- switching back and forth sends one email per real change
      pm := billing.active_method(o.account);
      if pm.id is distinct from o.ref::uuid
         or extract(epoch from coalesce(pm.activated_at, pm.created_at))::bigint::text is distinct from split_part(o.dedupe_key, ':', 3) then
        return 'card replaced';
      end if;
    when 'renewal_soon' then
      if st.state <> 'active' or st.cancel_at is not null or st.sub is distinct from o.ref::uuid then return 'not renewing'; end if;
    when 'card_expiring' then
      if (billing.active_method(o.account)).id is distinct from o.ref::uuid then return 'card replaced'; end if;
      if not (billing.money_state(o.account, p_at, st.state)->>'card_expires_first')::boolean then return 'card fine'; end if;
    when 'trial_ends_soon' then
      if st.state <> 'trialing' or extract(epoch from st.trial_ends_at)::bigint::text <> o.ref then return 'week over or paid'; end if;
    when 'trial_ended' then
      if st.state <> 'ended' or exists (select 1 from billing.subscriptions x where x.account = o.account) then return 'paid'; end if;
    when 'history_delete_soon' then
      if st.state <> 'ended' then return 'plan running again'; end if;
      if not exists (select 1 from jsonb_array_elements(billing.account_state(o.account, p_at)->'plants') p
                      where (p->>'chosen')::boolean and (p->>'delete_at')::timestamptz > p_at) then return 'nothing kept'; end if;
    when 'history_deleted' then
      if st.state <> 'ended' then return 'plan running again'; end if;
      if not exists (select 1 from billing.plant_facts p where p.plant = o.ref::bigint and p.history_purged_at is not null) then
        return 'history back';
      end if;
  end case;
  return null;
end $function$;
