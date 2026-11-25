-- ============================================================================
-- 0276 — one reminder 3 days before an unpaid plan ends (SOLAR-654).
--
-- A refused card or no card sends one email on the day, then nothing until the plan ends (up
-- to 15 days). This adds payment_reminder: always sent (not a reminders-setting email, like
-- the other payment emails), once per unpaid renewal bill. A soft decline gets no reminder in
-- practice: a try is still coming when the 3 days begin, and the last try's own email goes the
-- day before the cutoff. Only if that last try never ran (a skipped run) does the reminder go.
--
--   When     from 08:00 local time, 3 days before the pay-by day (cutoff 8 Dec: from 5 Dec
--            08:00), until the cutoff. The account's time zone, as the cutoff uses.
--   Only if  the bill is the plan's open renewal bill, the plan is past due, no try is still
--            coming (next_try_on null), and no other payment email for the bill (payment_failed,
--            card_update, payment_due) was sent in the last 3 days.
--   Waits    (not queued, or held in outbox_take; never dropped) while a payment may still
--            land: a saved-card try or verified card page unanswered (renewal_hold), a card page
--            opened in the last hour, another payment email for the bill still queued, or a
--            saved card during the daily billing run (04:00-06:05 UTC).
--   Drops    at send time when any "only if" stops holding (outbox_guard). No stored expiry:
--            the check reads the cutoff at send time, so a time zone change moves it too.
--
-- billing.payment_reminder_check holds both lists; outbox_sweep (queue), outbox_guard (drop)
-- and outbox_take (hold) call it. Bodies: outbox_sweep 0247, outbox_guard and outbox_take
-- 0254; only the lines marked 0276 change.
--
-- Deploy order: notify first (it learns the email's words), then this migration. A row
-- notify has no words for fails for good ("nothing to say") and its key is used up.
-- ============================================================================

insert into billing.outbox_kinds (key, reminder) values ('payment_reminder', false);
create index outbox_invoice on billing.outbox (invoice, key) where invoice is not null;

-- Why a payment_reminder for bill p_inv may not go at p_at.
--   stop: it must never go (null: it may). wait: not yet (null: now).
create function billing.payment_reminder_check(p_account uuid, p_inv uuid, p_at timestamptz,
                                               out stop text, out wait text)
language plpgsql stable set search_path = billing, pg_temp as $$
declare
  st billing.status;
  inv billing.invoices;
  rs jsonb;
  tz text;
  h record;
begin
  select * into inv from billing.invoices where id = p_inv and account = p_account;
  if inv.id is null or inv.kind <> 'renewal' then stop := 'no renewal bill'; return; end if;
  if inv.status <> 'open' then stop := 'bill settled'; return; end if;
  st := billing.account_status(p_account, p_at);
  if st.state <> 'past_due' then stop := 'not past due'; return; end if;
  if st.plan_ends_at <= p_at then stop := 'past the pay-by date'; return; end if;
  rs := billing.renewal_state(p_account, p_at, st);
  if rs->'due_bill'->>'id' is distinct from inv.id::text then stop := 'a later bill'; return; end if;
  if rs->>'next_try_on' is not null then stop := 'a try is coming'; return; end if;
  if exists (select 1 from billing.outbox o where o.invoice = inv.id and o.key in ('payment_failed', 'card_update', 'payment_due')
                and o.status = 'sent' and o.sent_at > p_at - interval '3 days') then
    stop := 'payment email sent'; return;
  end if;
  select coalesce(a.time_zone, m.default_time_zone) into tz
    from billing.accounts a join billing.markets m on m.code = a.market where a.id = p_account;
  if p_at < (((st.plan_ends_at at time zone tz)::date - 3) + time '08:00') at time zone tz then
    wait := 'too early'; return;
  end if;

  select * into h from billing.renewal_hold(p_account, p_at);
  if h.in_flight or exists (select 1 from billing.payment_attempts pa where pa.invoice = inv.id and pa.channel = 'card_page'
                               and pa.status in ('created', 'pending', 'unknown') and pa.replaced_at is null
                               and pa.created_at > p_at - interval '1 hour') then
    wait := 'payment under way'; return;
  end if;
  if exists (select 1 from billing.outbox o where o.invoice = inv.id and o.key in ('payment_failed', 'card_update', 'payment_due')
                and o.status = 'queued') then
    wait := 'payment email waiting'; return;
  end if;
  -- the daily run (billing-run, */5 4-5 UTC, billing.next_run_at) may be charging the card now
  if (billing.active_method(p_account)).id is not null
     and (p_at at time zone 'UTC')::time >= time '04:00' and (p_at at time zone 'UTC')::time < time '06:05' then
    wait := 'billing run'; return;
  end if;
end $$;
revoke all on function billing.payment_reminder_check(uuid, uuid, timestamptz) from public, anon, authenticated;

-- outbox_sweep: a past-due account's open renewal bill, once its 3 days begin
create function billing.payment_reminder_put(p_account uuid, st billing.status, p_at timestamptz)
returns void language plpgsql set search_path = billing, pg_temp as $$
declare inv uuid; c record;
begin
  if st.plan_ends_at is null or st.plan_ends_at - p_at > interval '4 days' then return; end if;
  select id into inv from billing.invoices where subscription = st.sub and kind = 'renewal' and status = 'open'
   order by created_at desc limit 1;
  if inv is null then return; end if;
  select * into c from billing.payment_reminder_check(p_account, inv, p_at);
  if c.stop is null and c.wait is null then
    perform billing.outbox_put(p_account, 'payment_reminder', inv, null, 'payment_reminder:' || inv, p_at, null, p_at);
  end if;
end $$;
revoke all on function billing.payment_reminder_put(uuid, billing.status, timestamptz) from public, anon, authenticated;

do $$
declare
  d text;
  old text;
begin
  d := pg_get_functiondef('billing.outbox_sweep(timestamptz)'::regprocedure);
  old := $o$    elsif st.state = 'active' and st.sub is not null and st.cancel_at is null then$o$;
  if position(old in d) = 0 then raise exception 'outbox_sweep changed since 0247: edit it by hand'; end if;
  execute replace(d, old, $n$    elsif st.state = 'past_due' then
      perform billing.payment_reminder_put(a.id, st, p_at);                                    -- 0276
$n$ || old);

  d := pg_get_functiondef('billing.outbox_guard(billing.outbox, timestamptz)'::regprocedure);
  old := $o$    when 'refund' then$o$;
  if position(old in d) = 0 then raise exception 'outbox_guard changed since 0254: edit it by hand'; end if;
  execute replace(d, old, $n$    when 'payment_reminder' then                                                  -- 0276
      return (billing.payment_reminder_check(o.account, o.invoice, p_at)).stop;
$n$ || old);

  d := pg_get_functiondef('billing.outbox_take(int, timestamptz)'::regprocedure);
  old := $o$then billing.plan_ended_held(account, ref, p_at) else false end$o$;
  if position(old in d) = 0 then raise exception 'outbox_take changed since 0254: edit it by hand'; end if;
  execute replace(d, old, $n$then billing.plan_ended_held(account, ref, p_at)
                              when key = 'payment_reminder' then                                 -- 0276
                                (select c.stop is null and c.wait is not null
                                   from billing.payment_reminder_check(account, invoice, p_at) c)
                              else false end$n$);
end $$;
