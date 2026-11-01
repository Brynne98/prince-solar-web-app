-- ============================================================================
-- 0128 — the daily run in parts, refund outcomes, paid plants that do not start
-- (SOLAR-264, approved 2026-10-31).
--
-- The run. The billing function charges cards a few at a time and stops starting new
-- charges after a time budget; pg_cron calls it every 5 minutes for 2 hours, so the
-- next call takes what one call did not reach. A renewal charge the run handed out
-- and never heard back about is no longer failed ('not charged: the run stopped'):
-- the next run hands it out again with the same reference. Paystack refuses a reused
-- reference ("Duplicate Transaction Reference", seen in test mode 2026-10-31), and the
-- function then asks Paystack what became of the first try, so no card is charged
-- twice. claimed_at keeps two calls from handing out one charge: a claimed charge
-- comes back after 10 minutes (longer than a call can run), or on a later day. A
-- charge handed out again on a later day is that day's try, so day 1, 3, 7 and Free
-- on day 8 count from the tries really made. Free waits while a try is open. Two
-- limits: a charge no longer owed (settled another way, or the account moved on) is
-- closed, not charged; one still open at Paystack 3 days after its first try fails.
--
-- Refunds. A payment marked 'refund:' (paid, nothing applied) now goes back at once,
-- as a card change's R1 does (Brynne, 2026-10-31); before, it was refunded by hand.
-- billing_charge_refunded records both. Paystack's refund events (refund.processed,
-- refund.failed) come back through billing_charge_refund_event: a refused refund is
-- written on the charge and logged; a processed one dates refunded_at.
--
-- Paid plants. billing_charge_paid applies a start or upgrade in a sub-block: when a
-- Family plant the charge names still does not collect after billing_resume, the block
-- rolls back and the charge is marked 'refund:' like any payment that no longer fits.
-- ============================================================================

alter table private.billing_charges add column if not exists claimed_at timestamptz;  -- handed out to a run call
alter table private.billing_charges add column if not exists tried_on date;            -- first handed out

-- ---------------------------------------------------------------------------
-- 1. The daily run (0116's, with charges handed out again instead of failed)
-- ---------------------------------------------------------------------------
create or replace function public.billing_run(p_today date default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  today date := coalesce(p_today, private.billing_today());
  b private.billing;
  r jsonb;
  c private.billing_charges;
  ref text;
  out jsonb := '[]'::jsonb;
  p bigint;
begin
  -- One run at a time: a second run waits, then sees the first one's work (each
  -- query below reads after the lock), so nothing is renewed or retried twice.
  perform pg_advisory_xact_lock(hashtext('billing_run'));

  -- A renewal handed out and not reported (the call ran out of time, crashed, or had
  -- no answer from Paystack): handed out again with its reference. On a later day it
  -- is that day's try.
  for c in select * from private.billing_charges
            where kind = 'renewal' and status = 'pending'
              and (claimed_at is null or claimed_at < now() - interval '10 minutes' or created_on < today)
            order by created_at, reference loop
    select * into b from private.billing where user_id = c.user_id;
    if private.billing_charge_stale(c, b) is not null then
      -- No longer owed: not charged again. A payment Paystack did take for it after all
      -- is marked for refund when it is reported (billing_charge_paid).
      update private.billing_charges set status = 'failed', error = 'not charged: no longer due', settled_at = now()
       where reference = c.reference;
      continue;
    end if;
    update private.billing_charges set created_on = greatest(created_on, today) where reference = c.reference;
    if c.tried_on <= today - 3 then
      perform public.billing_charge_failed(c.reference, 'not settled at Paystack 3 days after the first try');
      continue;
    end if;
    out := out || jsonb_build_object('reference', c.reference, 'amount', c.amount, 'card', b.card->>'authorization_code',
                                     'email', coalesce(b.card_email, (select email from auth.users where id = c.user_id)));
  end loop;

  -- Unpaid after the last try (day 7): Free. Not while a try is still open.
  for b in select * from private.billing bl
            where state = 'past_due' and today - past_due_since >= 8
              and not exists (select 1 from private.billing_charges x
                               where x.user_id = bl.user_id and x.kind = 'renewal' and x.status = 'pending') loop
    perform private.billing_to_free(b.user_id, today);
  end loop;

  -- Retries on day 1, 3 and 7, once a day.
  for b in select * from private.billing bl
            where state = 'past_due' and today - past_due_since in (1, 3, 7)
              and not exists (select 1 from private.billing_charges x
                               where x.user_id = bl.user_id and x.kind = 'renewal' and x.created_on = today) loop
    select * into c from private.billing_charges
     where user_id = b.user_id and kind = 'renewal' and due_on = b.past_due_since order by created_at limit 1;
    ref := 'psh_' || replace(gen_random_uuid()::text, '-', '');
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on)
    values (ref, b.user_id, 'renewal', c.plan, c.period, c.amount, c.due_on, today);
    out := out || jsonb_build_object('reference', ref, 'amount', c.amount, 'card', b.card->>'authorization_code',
                                     'email', coalesce(b.card_email, (select email from auth.users where id = b.user_id)));
  end loop;

  -- Billing dates.
  for b in select * from private.billing
            where plan <> 'free' and not comped and state = 'active' and next_billing_date <= today loop
    r := public.billing_renew(b.user_id);
    if (r->>'plan') <> 'free' and (r->>'charge')::int > 0 then
      ref := 'psh_' || replace(gen_random_uuid()::text, '-', '');
      insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on)
      select ref, b.user_id, 'renewal', bl.plan, bl.period, (r->>'charge')::int, b.next_billing_date, today
        from private.billing bl where bl.user_id = b.user_id;
      out := out || jsonb_build_object('reference', ref, 'amount', (r->>'charge')::int, 'card', b.card->>'authorization_code',
                                       'email', coalesce(b.card_email, (select email from auth.users where id = b.user_id)));
    end if;
  end loop;

  -- No saved card: fails now (the user gets the "pay with another card" email).
  for r in select x from jsonb_array_elements(out) x where x->>'card' is null loop
    perform public.billing_charge_failed(r->>'reference', 'no saved card');
  end loop;
  out := coalesce((select jsonb_agg(x) from jsonb_array_elements(out) x where x->>'card' is not null), '[]'::jsonb);
  update private.billing_charges set claimed_at = now(), tried_on = coalesce(tried_on, today)
   where reference in (select x->>'reference' from jsonb_array_elements(out) x);

  -- Booked removals due today.
  for b in select * from private.billing where remove_on <= today and cardinality(plants_to_remove) > 0 loop
    foreach p in array b.plants_to_remove loop perform private.billing_drop_plant(b.user_id, p); end loop;
    update private.billing set plants_to_remove = '{}', remove_on = null, updated_at = now() where user_id = b.user_id;
  end loop;

  -- 3 days before a removal.
  insert into public.email_queue (user_id, kind, key, data, priority)
  select bl.user_id, 'bill_removal_soon', 'bill_removal_soon:' || bl.remove_on,
         jsonb_build_object('on', bl.remove_on,
           'plants', (select jsonb_agg(pu.plant_name order by pu.linked_at) from public.plant_users pu
                       where pu.user_id = bl.user_id and pu.plant_id = any (bl.plants_to_remove))), 1
    from private.billing bl
   where bl.remove_on = today + 3 and cardinality(bl.plants_to_remove) > 0
  on conflict do nothing;

  -- Yearly plans, 60 days before the date.
  insert into public.email_queue (user_id, kind, key, data, priority)
  select bl.user_id, 'bill_renewal_notice', 'bill_renewal_notice:' || bl.next_billing_date,
         jsonb_build_object('plan', coalesce(bl.next_plan, bl.plan), 'on', bl.next_billing_date,
           'amount', public.billing_amount_due(bl.user_id),
           'changed', bl.next_plan is not null or bl.next_period is not null), 1
    from private.billing bl
   where bl.period = 'yearly' and not bl.comped and bl.state = 'active'
     and bl.next_billing_date = today + 60 and coalesce(bl.next_plan, bl.plan) <> 'free'
     and coalesce(bl.next_period, bl.period) = 'yearly'
  on conflict do nothing;

  return out;
end $$;

-- Charges the call handed out but did not start before its time ran out: the next
-- call takes them at once.
create or replace function public.billing_run_release(p_refs text[])
returns void language sql security definer set search_path = public, private, pg_temp as $$
  update private.billing_charges set claimed_at = null
   where reference = any (p_refs) and status = 'pending' and kind = 'renewal'
$$;
revoke all on function public.billing_run_release(text[]) from public, anon, authenticated;
grant execute on function public.billing_run_release(text[]) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Refund outcomes (Paystack refund.* events)
-- ---------------------------------------------------------------------------
-- 0120's, for marked payments too. refunded_at: when Paystack took the refund. A
-- refusal is written in front of the reason, which stays.
create or replace function public.billing_charge_refunded(p_reference text, p_error text default null)
returns void language sql security definer set search_path = public, private, pg_temp as $$
  update private.billing_charges
     set refunded_at = case when p_error is null then now() end,
         error = case when p_error is null then error
                      else left('refund failed: ' || p_error || coalesce(' | ' || error, ''), 300) end
   where reference = p_reference and status = 'paid' and refunded_at is null
     and (kind = 'card' or error like 'refund: %');
$$;

-- p_status: Paystack's refund status (pending, processing, processed, failed). Only
-- failed and processed change the charge. Answers false for a reference we never made.
create or replace function public.billing_charge_refund_event(p_reference text, p_status text, p_reason text default null)
returns boolean language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  if p_status = 'failed' then
    update private.billing_charges
       set error = left('refund failed: ' || coalesce(nullif(p_reason, ''), 'no reason given') || coalesce(' | ' || error, ''), 300)
     where reference = p_reference and status = 'paid' and coalesce(error, '') not like 'refund failed: %';
    if found then raise warning 'billing refund % failed: %', p_reference, p_reason; end if;
  elsif p_status = 'processed' then
    update private.billing_charges set refunded_at = coalesce(refunded_at, now())
     where reference = p_reference and status = 'paid';
  end if;
  return exists (select 1 from private.billing_charges where reference = p_reference);
end $$;
revoke all on function public.billing_charge_refund_event(text, text, text) from public, anon, authenticated;
grant execute on function public.billing_charge_refund_event(text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Paid (0127's), applied all or nothing
-- ---------------------------------------------------------------------------
create or replace function public.billing_charge_paid(p_reference text, p_card jsonb default null,
  p_quiet boolean default false, p_cents bigint default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  today date := private.billing_today();
  v_from text;
  stale text;
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then raise exception 'unknown reference' using errcode = 'P0002'; end if;
  if c.kind = 'card' then
    if c.status <> 'paid' then
      if p_cents is not null and p_cents <> c.amount * 100 then
        raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
      end if;
      update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;
      if p_card is not null and coalesce((p_card->>'reusable')::boolean, false) then
        update private.billing set card = p_card, card_email = (select email from auth.users where id = c.user_id),
               updated_at = now()
         where user_id = c.user_id;
      else
        update private.billing_charges set error = 'card not reusable: not saved' where reference = p_reference;
      end if;
    end if;
    return jsonb_build_object('status', 'paid', 'kind', 'card', 'refund', c.refunded_at is null,
      'saved', p_card is not null and coalesce((p_card->>'reusable')::boolean, false));
  end if;
  if c.status = 'paid' then return jsonb_build_object('status', 'paid', 'again', true, 'kind', c.kind); end if;
  if p_cents is not null and p_cents <> c.amount * 100 then
    raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
  end if;
  select * into b from private.billing where user_id = c.user_id for update;
  perform private.billing_lock(c.user_id);
  v_from := coalesce(b.plan, 'free');
  -- Paid, but the account has moved on since the charge was opened. Paystack has the
  -- money; nothing is applied. The error marks it for a refund from Paystack's dashboard.
  stale := private.billing_charge_stale(c, b);
  if stale is null then
    begin
      update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;

      if c.kind = 'start' then
        insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
        values (c.user_id, c.plan, c.period, extract(day from today)::int,
                public.billing_step(today, c.period, extract(day from today)::int, 1))
        on conflict (user_id) do update
          set plan = excluded.plan, period = excluded.period, billing_day = excluded.billing_day,
              next_billing_date = excluded.next_billing_date, next_plan = null, next_period = null,
              state = 'active', past_due_since = null, updated_at = now();
      elsif c.kind = 'upgrade' then
        -- A new plan replaces a booked change; more plants on the same plan keep it.
        update private.billing
           set next_plan = case when plan = c.plan then next_plan end, plan = c.plan, updated_at = now()
         where user_id = c.user_id;
      else  -- renewal, settle
        update private.billing set state = 'active', past_due_since = null, updated_at = now() where user_id = c.user_id;
      end if;
      if c.kind in ('start', 'upgrade') then
        perform private.billing_resume(c.user_id, c.plants);
        -- On Family every plant named was paid for (past the 3rd) or fits: each one
        -- collects, or nothing of this payment applies. Home and Free hold 1, so named
        -- plants past it stay stopped by design.
        if c.plan = 'family' and exists (select 1 from public.plant_users where user_id = c.user_id and plant_id = any (c.plants) and paused) then
          raise exception 'paid plants did not start' using errcode = 'BL001';
        end if;
      end if;
      if p_card is not null and coalesce((p_card->>'reusable')::boolean, false) then
        update private.billing set card = p_card, card_email = (select email from auth.users where id = c.user_id)
         where user_id = c.user_id;
      end if;
    exception when sqlstate 'BL001' then
      stale := 'paid plants did not start';
    end;
  end if;
  if stale is not null then
    update private.billing_charges set status = 'paid', settled_at = now(),
           error = case when stale = 'paid plants did not start' then 'refund: ' || stale
                        else 'refund: paid after the account changed (' || stale || '; ' || v_from || ', ' || coalesce(b.state, 'active') || ')' end
     where reference = p_reference;
    raise warning 'billing charge % paid but not applied (%): refund it', p_reference, stale;
    return jsonb_build_object('status', 'paid', 'applied', false, 'kind', c.kind);
  end if;

  if not p_quiet then
    select * into b from private.billing where user_id = c.user_id;
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (c.user_id,
            case when c.kind in ('start', 'upgrade') then 'bill_upgraded' else 'bill_paid' end,
            'bill:' || p_reference,
            jsonb_build_object('from', v_from, 'to', b.plan, 'plan', b.plan, 'period', b.period,
              'amount', c.amount, 'date', today, 'reference', p_reference,
              'card', private.billing_card_label(coalesce(p_card, b.card)),
              'added', c.added, 'daysLeft', b.next_billing_date - today,
              'extra', public.billing_extra_inverters(c.user_id),
              'extraEach', public.billing_amount('family', b.period, 1) - public.billing_amount('family', b.period, 0),
              'nextAmount', public.billing_amount_due(c.user_id), 'nextDate', b.next_billing_date),
            1)
    on conflict do nothing;
  end if;
  return jsonb_build_object('status', 'paid', 'plan', b.plan, 'kind', c.kind);
end $$;

-- ---------------------------------------------------------------------------
-- 4. pg_cron: every 5 minutes from 04:00 to 05:55 UTC; a call with nothing due does nothing
-- ---------------------------------------------------------------------------
do $$
declare fn_url text := 'https://pmakzojwhouamawgszrc.functions.supabase.co/billing/run';
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not enabled here - skipping billing-run schedule (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'billing-run') then
    perform cron.unschedule('billing-run');
  end if;
  perform cron.schedule('billing-run', '*/5 4-5 * * *', format($job$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
        'Content-Type', 'application/json'),
      body := '{}'::jsonb,
      timeout_milliseconds := 120000);
  $job$, fn_url));
end $$;
