CREATE OR REPLACE FUNCTION billing.apply_payment(p_reference text, p_tx jsonb, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  att billing.payment_attempts;
  inv billing.invoices;
  a billing.accounts;
  s billing.subscriptions;
  txs text := lower(coalesce(p_tx->>'status', ''));
  why text;
  rid uuid;
  pm uuid;
  hard boolean;
  paid timestamptz;
  revive boolean := false;
  msg text := coalesce(p_tx->>'gateway_response', p_tx->>'message', p_tx->>'status');
begin
  -- on hold for the way back (billing.pause_payments): nothing is applied; the caller answers
  -- an error, so Paystack sends its notice again and the card page's return checks again later
  lock table billing.payments_pause in share mode;
  if exists (select 1 from billing.payments_pause) then
    raise exception 'payments are on hold for an update' using errcode = '55000';
  end if;
  select * into att from billing.payment_attempts where reference = p_reference;
  if not found then
    -- an old charge the old billing settled (copy_from_old keeps every reference): paid there,
    -- so a success sent again is not money to give back
    if txs = 'success' and exists (select 1 from billing.old_references o where o.reference = p_reference and o.status = 'paid') then
      return jsonb_build_object('action', 'again', 'status', 'success', 'old', true);
    end if;
    if txs = 'success' and p_reference like 'psh\_%' and p_tx->>'reference' is not distinct from p_reference then
      -- our reference, no try we hold (the account was deleted with its rows, or never ours): money goes back
      rid := billing.refund_due(null, p_reference, null, upper(p_tx->>'currency'), 'unknown_account', p_at);
      return jsonb_build_object('action', 'refund', 'refund', rid, 'reason', 'unknown_account');
    end if;
    return jsonb_build_object('action', 'ignored');
  end if;
  if (p_tx ? 'reference' or txs = 'success') and p_tx->>'reference' is distinct from p_reference then
    raise exception 'answer for % does not match %', coalesce(p_tx->>'reference', '(none)'), p_reference;
  end if;

  select * into inv from billing.invoices where id = att.invoice;
  if inv.account is not null then
    select * into a from billing.accounts where id = inv.account for update;   -- lock order: account first
  end if;
  select * into att from billing.payment_attempts where id = att.id for update;
  select * into inv from billing.invoices where id = att.invoice for update;
  if inv.subscription is not null then select * into s from billing.subscriptions where id = inv.subscription for update; end if;

  if att.status in ('success', 'not_applied', 'reversed') then
    if txs = 'reversed' and att.status = 'success' then
      update billing.payment_attempts set status = 'reversed', gateway_response = msg where id = att.id;
      insert into billing.refunds (attempt, reference, account, amount_minor, currency, reason, status, created_at, updated_at)
      values (att.id, att.reference, a.id, att.amount_minor, att.currency, 'reversed', 'processed', p_at, p_at)
      on conflict (reference) where reason <> 'manual' do nothing;
      if a.id is not null then
        perform billing.log_event(a.id, p_at, 'paystack', 'payment_reversed', null,
                                  jsonb_build_object('invoice', inv.id, 'reference', att.reference), msg);
      end if;
      return billing.money_back(att, inv, null, 'reversed', p_at) || jsonb_build_object('kind', inv.kind);
    end if;
    return jsonb_build_object('action', 'again', 'status', att.status, 'kind', inv.kind);
  end if;
  -- a saved-card charge Paystack calls abandoned did not pay: a failed try (not a hard
  -- decline), so the unpaid window starts and the retry days hold. Only a card page the
  -- owner left is void.
  if txs = 'abandoned' and att.channel <> 'card_page' then
    txs := 'failed';
  end if;
  -- still open 24 hours after the try, by Paystack's own answer: a failed try, no lease. Not a
  -- card page: the owner may still pay on it, so it stays pending (verified, and blocking a
  -- saved-card charge) until Paystack gives a final answer
  if txs not in ('success', 'abandoned', 'not_found', 'failed', 'reversed', 'unknown')
     and att.channel <> 'card_page' and att.created_at <= p_at - interval '24 hours' then
    txs := 'failed';
    msg := 'still pending after 24 hours';
  end if;
  -- a renewal card page with no final answer 24 hours after its plan's cutoff: failed, so the
  -- plan_ended email and a restart stop waiting on it (0248)
  if txs not in ('success', 'abandoned', 'not_found', 'failed', 'reversed')
     and att.channel = 'card_page' and inv.kind = 'renewal'
     and p_at >= billing.sub_cutoff(inv.subscription) + interval '24 hours' then
    txs := 'failed';
    msg := 'timeout: no final answer 24 hours after the plan ended';
  end if;

  if txs = 'success' then
    paid := billing.paid_time(p_tx, att.created_at, p_at);
    -- the job ended the plan on day 15 while this renewal, paid before that, was on its way
    revive := inv.kind = 'renewal' and inv.status = 'void' and s.status = 'ended' and s.ended_at > paid
              and exists (select 1 from billing.account_events e where e.account = a.id and e.kind = 'plan_ended'
                             and e.reason = 'unpaid' and e.after->>'sub' = s.id::text)
              and not exists (select 1 from billing.subscriptions x where x.account = a.id and x.started_at > s.started_at)
              and not exists (select 1 from billing.invoices x where x.subscription = s.id and x.kind = 'renewal'
                                 and x.status <> 'void' and x.period_start >= inv.period_start and x.id <> inv.id);
    why := case
      when (p_tx->>'amount')::bigint is distinct from att.amount_minor
           or upper(p_tx->>'currency') is distinct from att.currency then 'wrong_amount'
      when a.id is null then 'unknown_account'
      -- refunded before the success came (an old charge Paystack refunded while pending): never applied
      when exists (select 1 from billing.refunds rf where rf.attempt = att.id) then 'stale'
      when inv.status = 'paid' then 'duplicate'
      when inv.status <> 'open' and not revive then 'stale'
      when inv.kind in ('purchase', 'upgrade') and inv.expected_version is distinct from a.version then 'stale'
      -- the clock wins: a plan past its cancel date or day 15 is over even if the job has not run
      when inv.kind = 'purchase' and (billing.account_status(a.id, paid)).sub is not null then 'stale'
      when revive then null
      -- paid after the pay-by date, on a page held open past it: too late, as on any other day
      when inv.kind = 'renewal' and s.status = 'past_due' and paid > billing.sub_cutoff(s.id) then 'stale'
      when inv.kind in ('upgrade', 'renewal') and (s.id is null or s.status not in ('active', 'past_due')) then 'stale'
      when inv.kind in ('upgrade', 'renewal') and (billing.account_status(a.id, paid)).sub is distinct from s.id then 'stale'
      when inv.kind = 'upgrade' and inv.period_key like '%@%'
           and (paid at time zone (select mk.default_time_zone from billing.markets mk where mk.code = a.market))::date
               <> (inv.created_at at time zone (select mk.default_time_zone from billing.markets mk where mk.code = a.market))::date
        then 'stale'
      when inv.kind = 'upgrade' and (s.period_start <> inv.period_start or inv.period_end <= paid or inv.period_end <= p_at
             or exists (select 1 from billing.invoices x where x.subscription = s.id and x.kind = 'renewal'
                           and x.status <> 'void' and x.period_start >= inv.period_end)) then 'stale'
      when inv.kind = 'renewal' and s.period_end <> inv.period_start then 'duplicate'
    end;
    if why is not null then
      update billing.payment_attempts set status = 'not_applied', settled_at = p_at, claimed_until = null,
                                          gateway_response = msg, verified_processing = false,
                                          verify_unanswered_at = null where id = att.id;
      -- a refund already on record for this try is the one: never a second, and no refund id
      -- back, so the caller sends nothing (one still owed goes with the daily job's refunds)
      rid := case when not exists (select 1 from billing.refunds rf where rf.attempt = att.id)
                  then billing.refund_due(att.id, att.reference, a.id, att.currency, why, p_at) end;
      if a.id is not null then
        perform billing.log_event(a.id, p_at, 'paystack', 'payment_refunded', null,
                                  jsonb_build_object('invoice', inv.id, 'reference', att.reference), why);
      end if;
      return jsonb_build_object('action', 'refund', 'refund', rid, 'reason', why, 'kind', inv.kind);
    end if;

    pm := billing.save_method(a.id, p_tx, p_at);
    update billing.payment_attempts set status = 'success', settled_at = paid, claimed_until = null,
                                        payment_method = coalesce(pm, payment_method), gateway_response = msg,
                                        verified_processing = false, verify_unanswered_at = null
     where id = att.id;
    update billing.invoices set status = 'paid', paid_at = paid where id = inv.id returning * into inv;
    declare held boolean := billing.reading_held(a.id, p_at);                   -- 0256
    begin
    case inv.kind
      when 'purchase' then perform billing.apply_purchase(inv, paid);
      when 'renewal' then perform billing.apply_renewal(inv, paid);
      when 'upgrade' then perform billing.apply_upgrade(inv, paid);
      else rid := billing.refund_due(att.id, att.reference, a.id, att.currency, 'card_check', p_at);
    end case;
    if held and inv.kind in ('purchase', 'renewal', 'upgrade') and not billing.reading_held(a.id, p_at) then
      perform billing.readings_resume(a.id, p_at);
    end if;
    end;
    perform billing.bump(a.id);
    perform billing.log_event(a.id, p_at, 'paystack', 'payment_applied', null,
                              jsonb_build_object('invoice', inv.id, 'kind', inv.kind, 'amount', att.amount_minor,
                                                 'reference', att.reference, 'paid_at', paid, 'revived', revive));
    return jsonb_build_object('action', 'applied', 'kind', inv.kind, 'refund', rid);
  end if;

  if txs in ('abandoned', 'not_found') then
    if att.status in ('created', 'pending', 'unknown') then
      update billing.payment_attempts set status = 'void', gateway_response = msg, settled_at = p_at, claimed_until = null,
                                          verified_processing = false, verify_unanswered_at = null
       where id = att.id;
    end if;
    return jsonb_build_object('action', 'void', 'kind', inv.kind);
  end if;

  if txs in ('failed', 'reversed') then
    if att.status = 'failed' then return jsonb_build_object('action', 'again', 'status', 'failed', 'kind', inv.kind); end if;
    hard := txs = 'failed' and billing.is_hard_decline(msg);
    update billing.payment_attempts set status = 'failed', hard_decline = hard, gateway_response = msg,
                                        settled_at = p_at, claimed_until = null, verified_processing = false,
                                        verify_unanswered_at = null
     where id = att.id;
    if hard and att.payment_method is not null then
      update billing.payment_methods set active = false, disabled_reason = 'hard_decline'
       where id = att.payment_method and active;
    end if;
    -- a card that will never work again on a charge the owner did not watch: ask for a new one
    if hard and a.id is not null and att.channel = 'saved_card' and inv.kind = 'renewal' then
      -- ref: the refused try, so the email names the card it removed
      insert into billing.outbox (account, key, invoice, ref, dedupe_key, not_before, created_at)
      values (a.id, 'card_update', inv.id, att.id::text, 'card_update:' || inv.id, p_at, p_at)
      on conflict (dedupe_key) do nothing;
    end if;
    if txs = 'failed' and inv.kind = 'renewal' and inv.status = 'open' and s.status = 'active' then
      update billing.subscriptions set status = 'past_due', past_due_since = inv.period_start, version = version + 1 where id = s.id;
      perform billing.bump(a.id);
      perform billing.log_event(a.id, p_at, 'paystack', 'renewal_failed', null,
                                jsonb_build_object('invoice', inv.id, 'reference', att.reference, 'hard', hard), msg);
    end if;
    return jsonb_build_object('action', 'failed', 'hard', hard, 'kind', inv.kind, 'declined', txs = 'failed');
  end if;

  if txs = 'unknown' then
    if att.status in ('created', 'unknown') then
      update billing.payment_attempts set status = 'unknown', gateway_response = msg, claimed_until = p_at + interval '10 minutes',
                                          verify_unanswered_at = null
       where id = att.id;
    end if;
    return jsonb_build_object('action', 'unknown');
  end if;

  -- still open: card page, bank challenge, processing. The daily job lets it go after 24 hours.
  -- A card page Paystack answered this way is a payment under way, not a page just opened
  -- (both are pending here): verified_processing tells them apart (0248).
  update billing.payment_attempts
     set status = 'pending', gateway_response = msg, claimed_until = p_at + interval '1 hour',
         verified_processing = (channel = 'card_page'), verify_unanswered_at = null,
         pay_url = coalesce(p_tx->>'authorization_url', p_tx->>'url', pay_url)
   where id = att.id and status in ('created', 'pending', 'unknown');
  if found and inv.kind = 'renewal' and inv.status = 'open' and s.status = 'active' and att.channel = 'saved_card' then
    -- the renewal was not paid on its day: the window starts, the owner has the pay link
    update billing.subscriptions set status = 'past_due', past_due_since = inv.period_start, version = version + 1 where id = s.id;
    perform billing.bump(a.id);
    perform billing.log_event(a.id, p_at, 'paystack', 'renewal_pending', null,
                              jsonb_build_object('invoice', inv.id, 'reference', att.reference), msg);
  end if;
  return jsonb_build_object('action', 'pending', 'pay_url', (select pay_url from billing.payment_attempts where id = att.id));
end $function$;
