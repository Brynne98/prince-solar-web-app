-- ============================================================================
-- 0132 — the rare cases left on SOLAR-264 (Brynne, 2026-10-31: fix them all).
--
-- Disputes. A lost dispute no longer makes the account past due on the spot when
-- something else is in flight: the charge is marked dispute_owed and the debt starts
-- on the first quiet day (paid plan, active, billing date passed, no renewal or settle
-- open), checked at once and by every daily run. Before, a dispute lost on the billing
-- date took that date, so the period was never renewed (S3); one lost while a renewal
-- was open refunded that renewal (S4); one lost while already past due was dropped
-- (S5). On Free or comped the debt is closed, not collected. Account delete waits
-- while one is owed.
-- Retries. A renewal Paystack keeps open 3 days now fails before its day is counted,
-- so that day still gets its retry (A7). A renewal handed out but never started (the
-- call ran out of time) gives back its day: billing_run_release restores created_on
-- and tried_on (A8).
-- Refunds. A refund.failed for an account already deleted alerts hello@ (RF7). The
-- hello@ alert for a stuck refund is marked on the charge, so it goes once (RF8). A
-- refund refused 7 times (hello@ told) no longer blocks account delete (D6). A card
-- check whose refund failed once and was then reversed reads as the card change (W6).
-- Card pages left unpaid 2 days are closed as failed; a late payment still applies or
-- is refunded as before (C1).
-- Plants. A paid start from Free cancels the deletions the move to Free booked: the
-- user pays now, so no plant is deleted for the old unpaid date; plants past the room
-- stay stopped (T2). The run's booked removals take the user lock and read the list
-- again, so a plant the user just started is not deleted, and the lock order matches
-- payments. billing_resume takes its plant locks in plant id order, as links do.
-- Billing: api_billing_status gives nextTry, the day the run tries the card again.
-- ============================================================================

alter table private.billing_charges add column if not exists dispute_owed boolean not null default false;
alter table private.billing_charges add column if not exists handed_from date;       -- created_on before a re-hand
alter table private.billing_charges add column if not exists refund_alerted boolean not null default false;

-- A lost dispute is owed from the first quiet day (0130's, with the debt moved out).
create or replace function public.billing_charge_disputed(p_reference text, p_status text, p_lost boolean,
  p_cents bigint default null)
returns boolean language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  today date := private.billing_today();
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then return false; end if;
  perform private.billing_lock(c.user_id);
  update private.billing_charges set dispute = left(coalesce(p_status, 'open'), 60) where reference = p_reference;
  if not p_lost or c.dispute_lost then return true; end if;
  update private.billing_charges
     set dispute_lost = true, refund_status = 'done', refunded_at = coalesce(refunded_at, now()),
         refunded_cents = coalesce(p_cents, amount * 100::bigint)
   where reference = p_reference;
  raise warning 'billing charge % disputed and lost', p_reference;
  -- Money that applied nothing, or a card check, takes nothing away.
  if c.status <> 'paid' or c.kind = 'card' or c.amount = 0 or c.error is not null then return true; end if;
  -- Owed from the first quiet day (0132): now, or a later daily run.
  update private.billing_charges set dispute_owed = true where reference = p_reference;
  perform private.billing_dispute_apply(c.user_id, today);
  return true;
end $$;
revoke all on function public.billing_charge_disputed(text, text, boolean, bigint) from public, anon, authenticated;
grant execute on function public.billing_charge_disputed(text, text, boolean, bigint) to service_role;

-- The oldest dispute owed becomes the debt: a failed renewal for today, past due from
-- today, tries on day 1, 3 and 7, Free on day 8 (0130's rule). Only on a quiet day: a
-- paid plan, active, its billing date passed, no renewal or settle open. Free or comped:
-- closed, not collected.
create or replace function private.billing_dispute_apply(p_user uuid, p_today date)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  c private.billing_charges;
  ref text := 'psh_' || replace(gen_random_uuid()::text, '-', '');
begin
  -- one lock order: the user's charge rows, the user lock, the billing row (0130)
  perform 1 from private.billing_charges where user_id = p_user and dispute_owed order by reference for update;
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  if b.user_id is null or b.plan = 'free' or b.comped then
    update private.billing_charges set dispute_owed = false,
           error = left(coalesce(error || ' | ', '') || 'dispute lost on Free: not collected', 300)
     where user_id = p_user and dispute_owed;
    return;
  end if;
  if b.state <> 'active' or b.next_billing_date <= p_today
     or exists (select 1 from private.billing_charges x where x.user_id = p_user
                 and x.kind in ('renewal', 'settle') and x.status = 'pending') then
    return;
  end if;
  select * into c from private.billing_charges where user_id = p_user and dispute_owed
   order by settled_at, reference limit 1 for update;
  if not found then return; end if;
  update private.billing_charges set dispute_owed = false where reference = c.reference;
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on, tried_on,
                                       status, error, settled_at)
  values (ref, p_user, 'renewal', b.plan, b.period, c.amount, p_today, p_today, p_today,
          'failed', 'dispute lost: ' || c.reference, now());
  update private.billing set state = 'past_due', past_due_since = p_today, updated_at = now() where user_id = p_user;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (p_user, 'bill_failed', 'bill:' || ref,
          jsonb_build_object('plan', b.plan, 'period', b.period, 'amount', c.amount,
            'card', private.billing_card_label(b.card), 'nextTry', p_today + 1, 'freeOn', p_today + 8,
            'disputed', (c.settled_at at time zone 'Africa/Johannesburg')::date),
          1)
  on conflict do nothing;
end $$;
revoke all on function private.billing_dispute_apply(uuid, date) from public, anon, authenticated;


-- 0130's run: expiry before the day is counted, removals under the user lock, disputes owed, old card pages.
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
  s int;
begin
  perform pg_advisory_xact_lock(hashtext('billing_run'));

  -- Lost disputes owed, on a quiet day (0132). First, before this call holds any user
  -- lock: they lock charge rows before the user, as a dispute event does.
  for b in select bl.* from private.billing bl
            where exists (select 1 from private.billing_charges x where x.user_id = bl.user_id and x.dispute_owed)
            order by bl.user_id loop
    perform private.billing_dispute_apply(b.user_id, today);
  end loop;

  -- A renewal handed out and not reported: handed out again with its reference.
  for c in select * from private.billing_charges
            where kind = 'renewal' and status = 'pending'
              and (claimed_at is null or claimed_at < now() - interval '10 minutes' or created_on < today)
            order by created_at, reference loop
    select * into b from private.billing where user_id = c.user_id;
    if private.billing_charge_stale(c, b) is not null then
      update private.billing_charges set status = 'failed', error = 'not charged: no longer due', settled_at = now()
       where reference = c.reference;
      continue;
    end if;
    -- Expired before its day is counted (0132), so today still gets its retry.
    if c.tried_on <= today - 3 then
      perform public.billing_charge_failed(c.reference, 'not settled at Paystack 3 days after the first try');
      continue;
    end if;
    -- handed_from: the day it was last handed out, given back if this call never starts it (0132)
    update private.billing_charges set handed_from = case when created_on < today then created_on else handed_from end,
           created_on = greatest(created_on, today) where reference = c.reference;
    out := out || jsonb_build_object('reference', c.reference, 'amount', c.amount, 'card', b.card->>'authorization_code',
                                     'email', coalesce(b.card_email, (select email from auth.users where id = c.user_id)));
  end loop;

  -- Free from day 8, once all four tries are made and none is open.
  for b in select * from private.billing bl
            where state = 'past_due' and today - past_due_since >= 8
              and not exists (select 1 from private.billing_charges x
                               where x.user_id = bl.user_id and x.kind = 'renewal' and x.status = 'pending') loop
    if private.billing_try_slot(b.user_id, b.past_due_since) is null then
      perform private.billing_to_free(b.user_id, today);
    end if;
  end loop;

  -- Retries: the next of day 1, 3 and 7 once its day has come; one a day, none while one is open.
  for b in select * from private.billing bl
            where state = 'past_due'
              and not exists (select 1 from private.billing_charges x
                               where x.user_id = bl.user_id and x.kind = 'renewal'
                                 and (x.created_on = today or x.status = 'pending')) loop
    s := private.billing_try_slot(b.user_id, b.past_due_since);
    continue when s is null or today - b.past_due_since < s;
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

  -- Booked removals due today, or missed. The user lock and the list read again (0132):
  -- a plant started meanwhile is off the list, and the lock order is a payment's.
  for b in select * from private.billing where remove_on <= today and cardinality(plants_to_remove) > 0 loop
    perform private.billing_lock(b.user_id);
    select * into b from private.billing where user_id = b.user_id for update;
    continue when b.remove_on is null or b.remove_on > today;
    foreach p in array (select array_agg(x order by x) from unnest(b.plants_to_remove) x) loop
      perform private.billing_drop_plant(b.user_id, p);
    end loop;
    update private.billing set plants_to_remove = '{}', remove_on = null, updated_at = now() where user_id = b.user_id;
  end loop;

  -- Card pages left unpaid 2 days: closed (0132). A late payment still applies or is refunded.
  update private.billing_charges set status = 'failed', error = 'card page not finished', settled_at = now()
   where status = 'pending' and kind in ('start', 'upgrade', 'settle', 'card') and created_at < now() - interval '2 days';

  -- Up to 3 days before a removal, once.
  insert into public.email_queue (user_id, kind, key, data, priority)
  select bl.user_id, 'bill_removal_soon', 'bill_removal_soon:' || bl.remove_on,
         jsonb_build_object('on', bl.remove_on,
           'plants', (select jsonb_agg(pu.plant_name order by pu.linked_at) from public.plant_users pu
                       where pu.user_id = bl.user_id and pu.plant_id = any (bl.plants_to_remove))), 1
    from private.billing bl
   where bl.remove_on > today and bl.remove_on <= today + 3 and cardinality(bl.plants_to_remove) > 0
  on conflict do nothing;

  -- Yearly plans, up to 60 days before the date, once.
  insert into public.email_queue (user_id, kind, key, data, priority)
  select bl.user_id, 'bill_renewal_notice', 'bill_renewal_notice:' || bl.next_billing_date,
         jsonb_build_object('plan', coalesce(bl.next_plan, bl.plan), 'on', bl.next_billing_date,
           'amount', public.billing_amount_due(bl.user_id),
           'changed', bl.next_plan is not null or bl.next_period is not null), 1
    from private.billing bl
   where bl.period = 'yearly' and not bl.comped and bl.state = 'active'
     and bl.next_billing_date > today and bl.next_billing_date <= today + 60
     and coalesce(bl.next_plan, bl.plan) <> 'free' and coalesce(bl.next_period, bl.period) = 'yearly'
  on conflict do nothing;

  return out;
end $$;

-- A charge a call handed out and never started gives back the day it took (0132).
create or replace function public.billing_run_release(p_refs text[])
returns void language sql security definer set search_path = public, private, pg_temp as $$
  update private.billing_charges
     set claimed_at = null,
         created_on = coalesce(handed_from, created_on), handed_from = null,
         tried_on = case when handed_from is null and tried_on = created_on then null else tried_on end
   where reference = any (p_refs) and status = 'pending' and kind = 'renewal'
$$;
revoke all on function public.billing_run_release(text[]) from public, anon, authenticated;
grant execute on function public.billing_run_release(text[]) to service_role;


-- 0130's failed; a card check is applied whatever its refund did (0132).
create or replace function public.billing_charge_failed(p_reference text, p_error text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  s int;
  next_try date;
  today date := private.billing_today();
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then raise exception 'unknown reference' using errcode = 'P0002'; end if;
  -- applied: false for a payment marked for refund, so /verify does not call it paid.
  if c.status <> 'pending' then
    return jsonb_build_object('status', c.status, 'again', true, 'kind', c.kind,
                              'applied', not coalesce(c.kind <> 'card' and c.error like 'refund%', false));
  end if;
  perform private.billing_lock(c.user_id);
  select * into b from private.billing where user_id = c.user_id for update;
  update private.billing_charges set status = 'failed', error = left(p_error, 300), settled_at = now()
   where reference = p_reference;
  if c.kind <> 'renewal' then return jsonb_build_object('status', 'failed'); end if;
  if b.plan is null or b.plan = 'free' or b.comped
     or exists (select 1 from private.billing_charges x
                 where x.user_id = c.user_id and x.kind in ('renewal', 'settle') and x.due_on = c.due_on
                   and x.status = 'paid' and x.error is null) then
    return jsonb_build_object('status', 'failed', 'owed', false);
  end if;

  update private.billing set state = 'past_due', past_due_since = coalesce(past_due_since, c.due_on), updated_at = now()
   where user_id = c.user_id
  returning * into b;
  s := private.billing_try_slot(c.user_id, b.past_due_since);
  next_try := case when s is not null then greatest(b.past_due_since + s, today + 1) end;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (c.user_id, 'bill_failed', 'bill:' || p_reference,
          jsonb_build_object('plan', c.plan, 'period', c.period, 'amount', c.amount,
            'card', private.billing_card_label(b.card), 'nextTry', next_try,
            'freeOn', greatest(b.past_due_since + 8, coalesce(next_try + 1, today + 1))),
          1)
  on conflict do nothing;
  return jsonb_build_object('status', 'failed', 'nextTry', next_try);
end $$;

-- 0130's refunded; the hello@ alert is marked on the charge, so it goes once (0132).
create or replace function public.billing_charge_refunded(p_reference text, p_error text default null)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare c private.billing_charges;
begin
  update private.billing_charges
     set refund_status = case when p_error is null then 'asked' else 'failed' end,
         refunded_at = case when p_error is null then now() end,
         refund_tries = refund_tries + 1, refund_tried_at = now(),
         error = case when p_error is null then private.billing_refund_reason(error)
                      else private.billing_refund_note(error, p_error) end
   where reference = p_reference and status = 'paid' and (kind = 'card' or error like 'refund%')
     and coalesce(refund_status, 'failed') = 'failed'
  returning * into c;
  if not found then return; end if;
  if p_error is null then
    perform private.billing_refund_mail(c);
    return;
  end if;
  raise warning 'billing refund % refused: %', p_reference, p_error;
  if c.refund_tries >= 7 and not c.refund_alerted then
    update private.billing_charges set refund_alerted = true where reference = p_reference;
    insert into public.email_queue (to_email, kind, key, data, priority)
    values ('hello@princesolarhub.co.za', 'bill_mail_failed', 'bill_refund_stuck:' || p_reference,
            jsonb_build_object('kind', 'refund refused 7 times: refund it by hand', 'key', p_reference,
              'user', c.user_id, 'error', left(p_error, 300)), 1)
    on conflict do nothing;
  end if;
end $$;

-- 0131's refund events; an unknown failed refund alerts hello@, alerts go once (0132).
create or replace function public.billing_charge_refund_event(p_reference text, p_status text, p_reason text default null,
  p_cents bigint default null, p_refund text default null)
returns boolean language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  got jsonb;
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then
    -- The account was deleted with a refund still asked: only hello@ can see to it (0132).
    if p_status = 'failed' then
      insert into public.email_queue (to_email, kind, key, data, priority)
      values ('hello@princesolarhub.co.za', 'bill_mail_failed', 'bill_refund_stuck:' || p_reference,
              jsonb_build_object('kind', 'refund failed for a deleted account: refund it by hand', 'key', p_reference,
                'user', '', 'error', left(coalesce(nullif(p_reason, ''), 'no reason given'), 300)), 1)
      on conflict do nothing;
    end if;
    return false;
  end if;
  if p_status = 'failed' then
    -- A refund paid out (or a dispute lost) stays done.
    update private.billing_charges
       set refund_status = case when refunds <> '{}' or refund_status = 'done' then refund_status else 'failed' end,
           refunded_at = case when refunds <> '{}' or refund_status = 'done' then refunded_at end,
           error = case when kind = 'card' or error like 'refund%'
                        then private.billing_refund_note(error, coalesce(nullif(p_reason, ''), 'no reason given')) else error end
     where reference = p_reference;
    raise warning 'billing refund % failed: %', p_reference, p_reason;
    -- Accepted, then failed, on the last try: the run asks no more, so hello@ is told (0131).
    if c.refund_tries >= 7 and c.refunds = '{}' and coalesce(c.refund_status, '') <> 'done' and not c.refund_alerted then
      update private.billing_charges set refund_alerted = true where reference = p_reference;
      insert into public.email_queue (to_email, kind, key, data, priority)
      values ('hello@princesolarhub.co.za', 'bill_mail_failed', 'bill_refund_stuck:' || p_reference,
              jsonb_build_object('kind', 'refund failed 7 times: refund it by hand', 'key', p_reference,
                'user', c.user_id, 'error', left(coalesce(nullif(p_reason, ''), 'no reason given'), 300)), 1)
      on conflict do nothing;
    end if;
  elsif p_status = 'processed' then
    got := c.refunds || jsonb_build_object(coalesce(p_refund, 'refund'), coalesce(p_cents, c.amount * 100::bigint));
    update private.billing_charges
       set refunds = got, refund_status = 'done', refunded_at = coalesce(refunded_at, now()),
           refunded_cents = (select sum(value::bigint) from jsonb_each_text(got))
     where reference = p_reference;
    perform private.billing_refund_mail(c);
  elsif p_status in ('pending', 'processing') then
    update private.billing_charges set refund_status = 'asked', refunded_at = coalesce(refunded_at, now())
     where reference = p_reference and coalesce(refund_status, 'failed') = 'failed';
    perform private.billing_refund_mail(c);
  end if;
  return true;
end $$;
revoke all on function public.billing_charge_refund_event(text, text, text, bigint, text) from public, anon, authenticated;
grant execute on function public.billing_charge_refund_event(text, text, text, bigint, text) to service_role;


-- 0130's delete; waits while a dispute is owed; a refund hello@ took over no longer blocks it (0132).
create or replace function public.api_account_delete()
returns jsonb
language plpgsql
security definer
set search_path = public, private, vault, pg_temp
as $$
declare
  uid uuid := auth.uid();
  b private.billing;
  acc record;
  p bigint;
  mine bigint[];
  orphans bigint[];
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  -- Charge rows before the user lock, as billing_charge_paid takes them.
  perform 1 from private.billing_charges where user_id = uid order by reference for update;
  perform private.billing_lock(uid);
  select * into b from private.billing where user_id = uid for update;
  if b.state = 'past_due' or exists (select 1 from private.billing_charges where user_id = uid and dispute_owed) then
    raise exception 'pay what is owed first' using errcode = '22023';
  end if;
  if exists (select 1 from private.billing_charges
              where user_id = uid and status = 'pending' and kind in ('start', 'upgrade', 'settle')
                and created_at > now() - interval '1 day') then
    raise exception 'a payment is open' using errcode = '22023';
  end if;
  -- Money still to go back: the charge row it needs goes with the account.
  if exists (select 1 from private.billing_charges
              where user_id = uid and status = 'paid' and (kind = 'card' or error like 'refund%')
                and coalesce(refund_status, 'failed') = 'failed' and not refund_alerted) then  -- alerted: hello@ refunds it
    raise exception 'a payment is open' using errcode = '22023';
  end if;
  if b.plan <> 'free' and not b.comped and b.next_plan is distinct from 'free' then
    raise exception 'cancel your plan first' using errcode = '22023';
  end if;

  for acc in select id from private.sunsynk_accounts where user_id = uid order by id loop
    perform pg_advisory_xact_lock(1, hashtext(acc.id::text));
  end loop;
  select coalesce(array_agg(plant_id order by plant_id), '{}') into mine
    from public.plant_users where user_id = uid;
  foreach p in array mine loop perform pg_advisory_xact_lock(p); end loop;
  select coalesce(array_agg(g order by g), '{}') into orphans
    from unnest(mine) g
   where not exists (select 1 from public.plant_users o where o.plant_id = g and o.user_id <> uid);

  for acc in select id, refresh_secret_id from private.sunsynk_accounts where user_id = uid loop
    if acc.refresh_secret_id is not null then delete from vault.secrets where id = acc.refresh_secret_id; end if;
    update private.inverters set account_id = null where account_id = acc.id;
  end loop;
  delete from private.sunsynk_accounts where user_id = uid;

  delete from public.plant_users where user_id = uid;
  perform private.plants_tombstone(orphans);

  insert into public.email_queue (to_email, kind, key, priority)
  select email, 'account_deleted', 'account_deleted:' || uid, 1 from auth.users where id = uid and email is not null
  on conflict do nothing;

  delete from public.profiles where user_id = uid;
  delete from auth.users where id = uid;
  return jsonb_build_object('deleted', true, 'plantsRemoved', coalesce(array_length(orphans, 1), 0));
end $$;
revoke all on function public.api_account_delete() from public, anon;
grant execute on function public.api_account_delete() to authenticated, service_role;


-- 0130's resume; plant locks in plant id order (0132).
create or replace function private.billing_resume(p_user uuid, p_plants bigint[])
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  r record;
  others boolean;
begin
  perform private.billing_lock(p_user);
  -- plant locks in plant id order first, as links take them (0132)
  perform pg_advisory_xact_lock(x.plant_id) from (select pu.plant_id from public.plant_users pu
     where pu.user_id = p_user and pu.paused and (p_plants is null or pu.plant_id = any (p_plants)) order by pu.plant_id) x;
  for r in select pu.plant_id from public.plant_users pu
            where pu.user_id = p_user and pu.paused and (p_plants is null or pu.plant_id = any (p_plants))
            order by pu.linked_at, pu.plant_id loop
    perform pg_advisory_xact_lock(r.plant_id);
    others := exists (select 1 from public.plant_users where plant_id = r.plant_id and not paused);
    begin
      update public.plant_users set paused = false where user_id = p_user and plant_id = r.plant_id;
    exception when sqlstate '22023' then
      exit;  -- the room is full
    end;
    if not others then perform private.plant_start_fill(r.plant_id); end if;
    update private.billing
       set plants_to_remove = array_remove(plants_to_remove, r.plant_id),
           remove_on = case when array_remove(plants_to_remove, r.plant_id) = '{}' then null else remove_on end
     where user_id = p_user and r.plant_id = any (plants_to_remove);
  end loop;
end $$;
revoke all on function private.billing_resume(uuid, bigint[]) from public, anon, authenticated;


-- 0131's paid; a start cancels the deletions the move to Free booked (0132).
create or replace function public.billing_charge_paid(p_reference text, p_card jsonb default null,
  p_quiet boolean default false, p_cents bigint default null, p_email text default null, p_paid_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  today date := private.billing_today();
  v_from text;
  stale text;
  reusable boolean := p_card is not null and coalesce((p_card->>'reusable')::boolean, false);
  new_card boolean;
  named bigint[];
  room int;
  room_only boolean := false;  -- more room on the same plan, no plant named (0131)
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then raise exception 'unknown reference' using errcode = 'P0002'; end if;
  perform private.billing_lock(c.user_id);
  select * into b from private.billing where user_id = c.user_id for update;
  -- Paystack saves a card under a new code; the same code is the card held.
  new_card := reusable and (p_card->>'authorization_code') is distinct from (b.card->>'authorization_code');
  if c.kind = 'card' then
    if c.status <> 'paid' then
      if p_cents is not null and p_cents <> c.amount * 100 then
        raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
      end if;
      update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;
      if new_card then
        update private.billing
           set card = p_card, card_email = coalesce(p_email, c.email, (select email from auth.users where id = c.user_id)),
               updated_at = now()
         where user_id = c.user_id;
      elsif not reusable then
        update private.billing_charges set error = 'card not reusable: not saved' where reference = p_reference;
      end if;
    end if;
    return jsonb_build_object('status', 'paid', 'kind', 'card', 'refund', coalesce(c.refund_status, 'failed') = 'failed',
      'saved', reusable);
  end if;
  if c.status = 'paid' then
    -- Marked for refund: every report of it says so, until Paystack has taken the refund.
    if c.error like 'refund%' then
      return jsonb_build_object('status', 'paid', 'applied', false, 'kind', c.kind,
        'refund', coalesce(c.refund_status, 'failed') = 'failed');
    end if;
    return jsonb_build_object('status', 'paid', 'again', true, 'kind', c.kind);
  end if;
  if p_cents is not null and p_cents <> c.amount * 100 then
    raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
  end if;
  v_from := coalesce(b.plan, 'free');
  -- Paystack reported a refund before the payment: the money is going back, so the
  -- payment never applies.
  if c.refund_status is not null then
    update private.billing_charges set status = 'paid', settled_at = now(),
           error = 'refund: refunded at Paystack before the payment was reported'
     where reference = p_reference
    returning * into c;
    -- the refund events came while the charge was pending, so none sent the email (0131)
    perform private.billing_refund_mail(c);
    raise warning 'billing charge % paid after its refund: not applied', p_reference;
    return jsonb_build_object('status', 'paid', 'applied', false, 'kind', c.kind, 'refund', c.refund_status = 'failed');
  end if;
  stale := private.billing_charge_stale(c, b, (p_paid_at at time zone 'Africa/Johannesburg')::date);
  if stale is null then
    begin
      update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;

      if c.kind = 'start' then
        insert into private.billing (user_id, plan, period, billing_day, next_billing_date, extra_plants)
        values (c.user_id, c.plan, c.period, extract(day from today)::int,
                public.billing_step(today, c.period, extract(day from today)::int, 1), c.extra_plants)
        on conflict (user_id) do update
          set plan = excluded.plan, period = excluded.period, billing_day = excluded.billing_day,
              next_billing_date = excluded.next_billing_date, extra_plants = excluded.extra_plants,
              next_plan = null, next_period = null, next_extra_plants = null,
              state = 'active', past_due_since = null, updated_at = now(),
              -- on Free every booking came from the move to Free: paying cancels them (0132)
              plants_to_remove = '{}', remove_on = null;
      elsif c.kind = 'upgrade' then
        update private.billing
           set next_plan = case when plan = c.plan then next_plan end, plan = c.plan,
               extra_plants = c.extra_plants, next_extra_plants = null, updated_at = now()
         where user_id = c.user_id;
      else  -- renewal, settle
        update private.billing set state = 'active', past_due_since = null, updated_at = now() where user_id = c.user_id;
      end if;
      if c.kind in ('start', 'upgrade') then
        -- The plants the room was bought for, if still stopped; else the oldest stopped.
        named := array(select plant_id from public.plant_users
                        where user_id = c.user_id and paused and plant_id = any (coalesce(c.plants, '{}')));
        -- More room on the same plan, no plant named: as many as bought, newest first
        -- (plants that linked stopped), not every plant the user stopped on purpose (0131).
        if cardinality(named) = 0 and c.kind = 'upgrade' and v_from = c.plan then
          room_only := true;  -- none to start (all booked for removal) starts none
          named := array(select plant_id from public.plant_users where user_id = c.user_id and paused
                            and plant_id <> all (coalesce(b.plants_to_remove, '{}'))
                          order by linked_at desc, plant_id desc limit greatest(c.added, 0));
        end if;
        if cardinality(named) > 0 or not room_only then
          perform private.billing_resume(c.user_id, case when cardinality(named) > 0 then named end);
        end if;
        -- A bigger plan fills the rest of its room too, oldest first (0131): the named plant
        -- first, then the plants the old plan's limit stopped.
        if cardinality(named) > 0 and v_from <> c.plan then perform private.billing_resume(c.user_id, null); end if;
        select * into b from private.billing where user_id = c.user_id;
        room := least(public.billing_room(b.plan, b.extra_plants), coalesce(private.billing_next_room(b), 2147483647));
        -- Room left and a plant to start still stopped: the start was refused part way.
        if (select count(*) from public.plant_users where user_id = c.user_id and not paused) < room
           and exists (select 1 from public.plant_users where user_id = c.user_id and paused
                        and ((cardinality(named) = 0 and not room_only) or plant_id = any (named))) then
          raise exception 'paid plants did not start' using errcode = 'BL001';
        end if;
      end if;
      if new_card then
        update private.billing
           set card = p_card, card_email = coalesce(p_email, c.email, (select email from auth.users where id = c.user_id))
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
    return jsonb_build_object('status', 'paid', 'applied', false, 'kind', c.kind, 'refund', true);
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
              'extra', b.extra_plants,
              'extraEach', public.billing_amount('family', b.period, 1) - public.billing_amount('family', b.period, 0),
              'nextAmount', public.billing_amount_due(c.user_id), 'nextDate', b.next_billing_date),
            1)
    on conflict do nothing;
  end if;
  return jsonb_build_object('status', 'paid', 'plan', b.plan, 'kind', c.kind);
end $$;
revoke all on function public.billing_charge_paid(text, jsonb, boolean, bigint, text, timestamptz) from public, anon, authenticated;
grant execute on function public.billing_charge_paid(text, jsonb, boolean, bigint, text, timestamptz) to service_role;


-- 0131's status, with nextTry (0132).
create or replace function public.api_billing_status()
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  slot int;
  next_try date;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid();
  -- past due: the next day the run tries the card (the morning run; tomorrow once today's is made),
  -- and Free the day after the last try, day 8 at the earliest (as bill_failed says)
  if b.state = 'past_due' then
    slot := private.billing_try_slot(b.user_id, b.past_due_since);
    next_try := case when slot is not null then greatest(b.past_due_since + slot, private.billing_today()
      + case when exists (select 1 from private.billing_charges x where x.user_id = b.user_id and x.kind = 'renewal'
                           and x.created_on = private.billing_today()) then 1 else 0 end) end;
  end if;
  return jsonb_build_object(
    'plan', coalesce(b.plan, 'free'), 'period', b.period, 'state', coalesce(b.state, 'active'),
    'comped', coalesce(b.comped, false),
    'nextDate', b.next_billing_date,
    -- past due: the day the account moves to Free if nothing is paid (day 8, as bill_failed says)
    'nextTry', next_try,
    'freeOn', case when b.state = 'past_due' then greatest(b.past_due_since + 8, next_try + 1) end,
    'nextAmount', public.billing_amount_due(auth.uid()),
    'price', public.billing_amount(coalesce(b.plan, 'free'), b.period, coalesce(b.extra_plants, 0)),
    'extraPlants', coalesce(b.extra_plants, 0), 'nextExtraPlants', b.next_extra_plants,
    'nextPlan', b.next_plan, 'nextPeriod', b.next_period,
    'removeOn', b.remove_on,
    'removePlants', coalesce((select jsonb_agg(jsonb_build_object('id', pu.plant_id, 'name', pu.plant_name) order by pu.linked_at)
                                from public.plant_users pu
                               where pu.user_id = auth.uid() and pu.plant_id = any (coalesce(b.plants_to_remove, '{}'))), '[]'::jsonb),
    'card', case when b.card is not null then jsonb_build_object(
              'name', initcap(trim(coalesce(nullif(trim(b.card->>'card_type'), ''), b.card->>'brand', 'card'))),
              'brand', lower(trim(coalesce(nullif(trim(b.card->>'card_type'), ''), b.card->>'brand', 'card'))),
              'last4', b.card->>'last4', 'expMonth', b.card->>'exp_month', 'expYear', b.card->>'exp_year') end,
    'payments', coalesce((select jsonb_agg(p order by p->>'at' desc) from (
                  select jsonb_build_object('at', c.settled_at, 'date', (c.settled_at at time zone 'Africa/Johannesburg')::date,
                           'kind', c.kind, 'plan', c.plan, 'period', c.period, 'amount', c.amount) p
                    from private.billing_charges c
                   where c.user_id = auth.uid() and c.status = 'paid' and c.kind <> 'card' and c.amount > 0
                     and c.error is null and coalesce(c.refund_status, 'failed') = 'failed'
                   order by c.settled_at desc limit 6) x), '[]'::jsonb),
    'prices', jsonb_build_object(
      'monthly', jsonb_build_object('home', public.billing_amount('home', 'monthly'), 'family', public.billing_amount('family', 'monthly'),
                   'extra', public.billing_amount('family', 'monthly', 1) - public.billing_amount('family', 'monthly')),
      'yearly', jsonb_build_object('home', public.billing_amount('home', 'yearly'), 'family', public.billing_amount('family', 'yearly'),
                   'extra', public.billing_amount('family', 'yearly', 1) - public.billing_amount('family', 'yearly'))));
end $$;
