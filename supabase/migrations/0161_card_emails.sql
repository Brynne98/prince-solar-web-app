-- ============================================================================
-- 0161 — Card emails (SOLAR-406).
--
--   bill_card_changed   after a card change (the R1 card check, 0120): the new card,
--                       the one it replaced and the next payment. A security notice too.
--   bill_card_expiring  the saved card expires before the next payment: 30 days before
--                       its last day, then a last reminder 7 days before.
--
-- Cards read "Visa •••• 4081" (billing_card_label, 0140). No switch turns these off:
-- they are about money, like the other bill_ emails.
-- ============================================================================

-- A card change saves the new card in the same transaction that marks its R1 charge
-- paid (billing_charge_paid, 0155), so settled_at = now() tells a card change apart from
-- a new card saved by an upgrade or a failed payment paid with another card; those have
-- their own receipt.
create or replace function private.card_changed_mail()
returns trigger language plpgsql security definer set search_path = public, private, pg_temp as $$
declare cancel_booked boolean := coalesce(new.next_plan, new.plan) = 'free';
begin
  if old.card is null or new.card is null
     or (new.card->>'authorization_code') is not distinct from (old.card->>'authorization_code')
     or not exists (select 1 from private.billing_charges c
                     where c.user_id = new.user_id and c.kind = 'card' and c.status = 'paid' and c.settled_at = now()) then
    return null;
  end if;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (new.user_id, 'bill_card_changed', 'bill_card_changed:' || (new.card->>'authorization_code'),
          -- the same card saved again under a new code: no "It replaces" line
          jsonb_build_object('card', private.billing_card_label(new.card),
            'was', nullif(private.billing_card_label(old.card), private.billing_card_label(new.card)),
            -- no next payment once a cancel is booked
            'nextAmount', case when not cancel_booked then public.billing_amount_due(new.user_id) end,
            'nextDate', case when not cancel_booked then new.next_billing_date end), 1)
  on conflict do nothing;
  return null;
end $$;
revoke all on function private.card_changed_mail() from public, anon, authenticated;

drop trigger if exists billing_card_changed_mail on private.billing;
create trigger billing_card_changed_mail after update of card on private.billing
  for each row execute function private.card_changed_mail();

-- Once a day: cards whose last day (end of the expiry month) falls before the next
-- payment. First email 8 to 30 days before that day, last reminder 0 to 7 days before.
-- Keyed per card, so a new card starts again and each email goes once. A card first seen
-- 7 days or less before its last day gets one email, not called a last reminder.
create or replace function private.card_expiry_mail(p_today date default null)
returns int language plpgsql security definer set search_path = public, private, pg_temp as $$
declare n int; today date := coalesce(p_today, private.billing_today());
begin
  insert into public.email_queue (user_id, kind, key, data, priority)
  select c.user_id, 'bill_card_expiring',
         'bill_card_expiring:' || (c.card->>'authorization_code') || case when c.ends - today <= 7 then ':last' else ':first' end,
         jsonb_build_object('card', private.billing_card_label(c.card), 'on', c.ends, 'final', c.ends - today <= 7 and exists (select 1 from public.email_queue q
             where q.user_id = c.user_id and q.key = 'bill_card_expiring:' || (c.card->>'authorization_code') || ':first'),
           'nextAmount', public.billing_amount_due(c.user_id), 'nextDate', c.next_billing_date), 1
    -- exp_year as "2030" or "30"
    from (select b.*, (make_date((b.card->>'exp_year')::int + case when length(b.card->>'exp_year') = 2 then 2000 else 0 end,
                                 (b.card->>'exp_month')::int, 1) + interval '1 month - 1 day')::date as ends
            from private.billing b
           where b.card->>'exp_year' ~ '^(\d{2}|\d{4})$' and b.card->>'exp_month' ~ '^\d{1,2}$'
             and (b.card->>'exp_month')::int between 1 and 12) c
   where c.plan <> 'free' and not c.comped and c.state = 'active' and coalesce(c.next_plan, c.plan) <> 'free'
     and c.next_billing_date > c.ends and c.ends >= today and c.ends - today <= 30
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function private.card_expiry_mail(date) from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping jobs (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'card-expiry-mail') then
    perform cron.unschedule('card-expiry-mail');
  end if;
  perform cron.schedule('card-expiry-mail', '35 6 * * *', 'select private.card_expiry_mail()');
end $$;
