-- ============================================================================
-- 0116 — payments (SOLAR-208, Paystack part). The billing edge function talks to
-- Paystack; everything it decides with is here.
--
-- Every attempt to take money is one row in private.billing_charges, keyed by the
-- Paystack reference. A charge is opened (billing_charge_open, or the daily run),
-- the function charges the saved card or sends the user to Paystack's card page,
-- then reports back: billing_charge_paid or billing_charge_failed. Both are safe to
-- call twice (webhook and the return from the card page can both report one payment).
--
-- Kinds:
--   start    Free to Home or Family. Full price; the period starts today and the
--            bill falls on today's day of the month from now on.
--   upgrade  Home to Family, or more inverters past the 3rd plant on Family. The
--            difference for the days left (billing_upgrade_quote); the date stays.
--   renewal  the billing date's charge, and its retries.
--   settle   the user pays a failed renewal themselves, with another card.
--
-- The daily run (billing_run, decided on SOLAR-208 2026-10-27):
--   - billing date: booked changes apply (billing_renew), the new amount is charged
--   - a failed charge is retried on day 1, 3 and 7 after the billing date; each
--     failure emails the user. Still unpaid on day 8: Free. The first-linked plant
--     stays live; the others are paused and deleted after 30 days.
--   - plants booked for removal are deleted on their date (remove_on), and the
--     user is told 3 days before. A login left with no plant goes too.
--   - yearly plans get a renewal notice 60 days before the date (SOLAR-104).
-- Billing days are South African dates.
-- ============================================================================

create table if not exists private.billing_charges (
  reference   text primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  kind        text not null check (kind in ('start', 'upgrade', 'renewal', 'settle')),
  plan        text not null check (plan in ('home', 'family')),
  period      text not null check (period in ('monthly', 'yearly')),
  added       int not null default 0,     -- upgrade: inverters it adds past the 3rd plant
  amount      int not null check (amount >= 0),  -- whole rand; 0 = an upgrade that rounds to nothing
  status      text not null default 'pending' check (status in ('pending', 'paid', 'failed')),
  error       text,
  due_on      date not null,              -- renewal: the billing date it is for
  created_on  date not null,
  created_at  timestamptz not null default now(),
  settled_at  timestamptz
);
create index if not exists billing_charges_user_idx on private.billing_charges (user_id, created_at desc);
revoke all on table private.billing_charges from public, anon, authenticated;
grant all on table private.billing_charges to service_role;

create or replace function private.billing_today()
returns date language sql stable as $$ select (now() at time zone 'Africa/Johannesburg')::date $$;

-- "Visa ending 4081" from a Paystack authorization.
create or replace function private.billing_card_label(p_card jsonb)
returns text language sql immutable as $$
  select case when p_card is null then 'Your card'
    else initcap(trim(coalesce(nullif(trim(p_card->>'card_type'), ''), p_card->>'brand', 'card')))
         || ' ending ' || coalesce(p_card->>'last4', '????') end
$$;

-- ---------------------------------------------------------------------------
-- 1. Open a charge
-- ---------------------------------------------------------------------------
-- The user's own upgrade or start. Returns {reference, amount, email, card} with
-- card = the saved authorization code, or {amount: 0} when there is nothing to pay
-- (an upgrade on the last day can round to R0; it is applied at once).
create or replace function public.billing_charge_open(
  p_user uuid, p_plan text, p_period text default null, p_added int default 0)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  q jsonb;
  ref text := 'psh_' || replace(gen_random_uuid()::text, '-', '');
  v_kind text;
  v_period text;
  today date := private.billing_today();
begin
  select * into b from private.billing where user_id = p_user for update;
  if b.comped then raise exception 'this plan is free of charge' using errcode = '22023'; end if;
  if b.state = 'past_due' then raise exception 'settle the failed payment first' using errcode = '22023'; end if;
  v_kind := case when coalesce(b.plan, 'free') = 'free' then 'start' else 'upgrade' end;
  v_period := case when v_kind = 'start' then coalesce(p_period, 'monthly') else b.period end;
  q := public.billing_upgrade_quote(p_user, p_plan, greatest(p_added, 0),
         case when v_kind = 'start' then v_period end, today);
  if (q->>'dueNow')::int <= 0 then
    insert into private.billing_charges (reference, user_id, kind, plan, period, added, amount, due_on, created_on)
    values (ref, p_user, v_kind, p_plan, v_period, greatest(p_added, 0), 0, today, today);
    perform public.billing_charge_paid(ref, null, true);
    return jsonb_build_object('amount', 0, 'reference', ref);
  end if;
  insert into private.billing_charges (reference, user_id, kind, plan, period, added, amount, due_on, created_on)
  values (ref, p_user, v_kind, p_plan, v_period, greatest(p_added, 0), (q->>'dueNow')::int, today, today);
  return jsonb_build_object('reference', ref, 'amount', (q->>'dueNow')::int,
    'email', (select email from auth.users where id = p_user),
    'card', b.card->>'authorization_code');
end $$;

-- Pay a failed renewal now, with another card (Paystack's card page).
create or replace function public.billing_settle_open(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  c private.billing_charges;
  ref text := 'psh_' || replace(gen_random_uuid()::text, '-', '');
begin
  select * into b from private.billing where user_id = p_user for update;
  if b.state is distinct from 'past_due' then raise exception 'nothing to pay' using errcode = '22023'; end if;
  select * into c from private.billing_charges
   where user_id = p_user and kind in ('renewal', 'settle') and due_on = b.past_due_since
   order by created_at desc limit 1;
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on)
  values (ref, p_user, 'settle', c.plan, c.period, c.amount, c.due_on, private.billing_today());
  return jsonb_build_object('reference', ref, 'amount', c.amount,
    'email', (select email from auth.users where id = p_user));
end $$;

-- ---------------------------------------------------------------------------
-- 2. Paid
-- ---------------------------------------------------------------------------
-- Resume paused plants the new plan covers, in link order: Home 1, Family 3, then
-- plants past the 3rd while their inverters fit in p_added.
create or replace function private.billing_resume(p_user uuid, p_plan text, p_added int)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  active int := (select count(*) from public.plant_users where user_id = p_user and not paused);
  room int := p_added;
  r record;
begin
  for r in select pu.plant_id, (select count(*) from private.inverters i where i.plant_id = pu.plant_id)::int as inv
             from public.plant_users pu
            where pu.user_id = p_user and pu.paused
              and pu.plant_id <> all (coalesce((select plants_to_remove from private.billing where user_id = p_user), '{}'))
            order by pu.linked_at, pu.plant_id loop
    if active < coalesce(public.billing_plant_limit(p_plan), 3) then
      null;
    elsif p_plan = 'family' and r.inv <= room then
      room := room - r.inv;
    else
      exit;
    end if;
    update public.plant_users set paused = false where user_id = p_user and plant_id = r.plant_id;
    active := active + 1;
  end loop;
end $$;

-- p_card: Paystack's authorization object; saved when Paystack says it can be charged
-- again. p_cents: what Paystack says it took, checked against the charge. p_quiet: no
-- email (an upgrade that cost R0).
create or replace function public.billing_charge_paid(p_reference text, p_card jsonb default null,
  p_quiet boolean default false, p_cents bigint default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  today date := private.billing_today();
  v_from text;
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then raise exception 'unknown reference' using errcode = 'P0002'; end if;
  if c.status = 'paid' then return jsonb_build_object('status', 'paid', 'again', true); end if;
  if p_cents is not null and p_cents <> c.amount * 100 then
    raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
  end if;
  select * into b from private.billing where user_id = c.user_id for update;
  v_from := coalesce(b.plan, 'free');
  update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;

  if c.kind = 'start' then
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
    values (c.user_id, c.plan, c.period, extract(day from today)::int,
            public.billing_step(today, c.period, extract(day from today)::int, 1))
    on conflict (user_id) do update
      set plan = excluded.plan, period = excluded.period, billing_day = excluded.billing_day,
          next_billing_date = excluded.next_billing_date, next_plan = null, next_period = null,
          state = 'active', past_due_since = null, updated_at = now(),
          -- on Free, booked removals only come from a failed payment: paying keeps them
          plants_to_remove = '{}', remove_on = null;
  elsif c.kind = 'upgrade' then
    update private.billing set plan = c.plan, next_plan = null, updated_at = now()
     where user_id = c.user_id;
  else  -- renewal, settle
    update private.billing set state = 'active', past_due_since = null, updated_at = now() where user_id = c.user_id;
  end if;
  if c.kind in ('start', 'upgrade') then
    perform private.billing_resume(c.user_id, c.plan, c.added);
  end if;
  if p_card is not null and coalesce((p_card->>'reusable')::boolean, false) then
    update private.billing set card = p_card, card_email = (select email from auth.users where id = c.user_id)
     where user_id = c.user_id;
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
  return jsonb_build_object('status', 'paid', 'plan', b.plan);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Failed
-- ---------------------------------------------------------------------------
-- A failed start, upgrade or settle changes nothing: the user is on the page and
-- sees it. A failed renewal makes the account past due and emails the user.
create or replace function public.billing_charge_failed(p_reference text, p_error text)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  try_day int;
  next_try date;
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then raise exception 'unknown reference' using errcode = 'P0002'; end if;
  if c.status <> 'pending' then return jsonb_build_object('status', c.status, 'again', true); end if;
  update private.billing_charges set status = 'failed', error = left(p_error, 300), settled_at = now()
   where reference = p_reference;
  if c.kind <> 'renewal' then return jsonb_build_object('status', 'failed'); end if;

  update private.billing set state = 'past_due', past_due_since = coalesce(past_due_since, c.due_on), updated_at = now()
   where user_id = c.user_id
  returning * into b;
  try_day := c.created_on - b.past_due_since;
  next_try := b.past_due_since + case when try_day < 1 then 1 when try_day < 3 then 3 when try_day < 7 then 7 end;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (c.user_id, 'bill_failed', 'bill:' || p_reference,
          jsonb_build_object('plan', c.plan, 'period', c.period, 'amount', c.amount,
            'card', private.billing_card_label(b.card), 'nextTry', next_try, 'freeOn', b.past_due_since + 8),
          1)
  on conflict do nothing;
  return jsonb_build_object('status', 'failed', 'nextTry', next_try);
end $$;

-- ---------------------------------------------------------------------------
-- 4. The daily run
-- ---------------------------------------------------------------------------
-- Unpaid past the last try: Free keeps the first-linked plant, pauses the others,
-- deletes them after 30 days.
create or replace function private.billing_to_free(p_user uuid, p_today date)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  keep bigint;
  stop bigint[];
begin
  select * into b from private.billing where user_id = p_user for update;
  select plant_id into keep from public.plant_users where user_id = p_user
   order by linked_at, plant_id limit 1;
  select coalesce(array_agg(plant_id order by plant_id), '{}') into stop
    from public.plant_users where user_id = p_user and plant_id is distinct from keep;
  update private.billing
     set plan = 'free', period = null, billing_day = null, next_billing_date = null,
         next_plan = null, next_period = null, state = 'active', past_due_since = null,
         plants_to_remove = array(select distinct x from unnest(plants_to_remove || stop) x order by x),
         remove_on = case when cardinality(stop) > 0 then p_today + 30 else remove_on end,
         updated_at = now()
   where user_id = p_user;
  update public.plant_users set paused = (plant_id is distinct from keep) where user_id = p_user;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (p_user, 'bill_free', 'bill_free:' || p_today,
          jsonb_build_object('from', b.plan, 'deleteOn', p_today + 30,
            'kept', coalesce((select plant_name from public.plant_users where user_id = p_user and plant_id = keep), ''),
            'stopped', coalesce((select jsonb_agg(plant_name order by linked_at) from public.plant_users
                                  where user_id = p_user and plant_id = any (stop)), '[]'::jsonb)),
          1)
  on conflict do nothing;
end $$;

-- Delete one plant for one user, as Remove login does for a whole login: the row,
-- its queued mail, the data when no one else has the plant, and the login itself
-- when it has no plant left.
create or replace function private.billing_drop_plant(p_user uuid, p_plant bigint)
returns void language plpgsql set search_path = public, private, vault, pg_temp as $$
declare acc uuid; sid uuid;
begin
  select account_id into acc from public.plant_users where user_id = p_user and plant_id = p_plant;
  if acc is not null then perform pg_advisory_xact_lock(1, hashtext(acc::text)); end if;
  perform pg_advisory_xact_lock(p_plant);
  delete from public.plant_users where user_id = p_user and plant_id = p_plant;
  delete from public.email_queue where user_id = p_user and plant_id = p_plant and kind not like 'sunsynk_%';
  if not exists (select 1 from public.plant_users where plant_id = p_plant) then
    perform private.plants_tombstone(array[p_plant]);
  end if;
  if acc is not null and not exists (select 1 from public.plant_users where account_id = acc) then
    delete from public.email_queue where user_id = p_user and key like 'needs_relink:' || acc || ':%';
    select refresh_secret_id into sid from private.sunsynk_accounts where id = acc;
    if sid is not null then delete from vault.secrets where id = sid; end if;
    update private.inverters set account_id = null where account_id = acc;
    delete from private.sunsynk_accounts where id = acc;
  end if;
end $$;

-- One run for p_today. Does everything that needs no card, and returns the charges
-- to make: [{reference, amount, email, card}]. The function charges them and reports
-- back. A charge with no saved card fails here.
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
  -- Unpaid after the last try (day 7): Free.
  for b in select * from private.billing where state = 'past_due' and today - past_due_since >= 8 loop
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

-- ---------------------------------------------------------------------------
-- 5. A booked change is emailed (0113's call, plus the email)
-- ---------------------------------------------------------------------------
create or replace function public.api_billing_change(p_plan text, p_period text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform public.billing_book_change(auth.uid(), p_plan, p_period);
  select * into b from private.billing where user_id = auth.uid();
  -- An undo (back to the current plan and period) sends nothing.
  if b.next_plan is not null or b.next_period is not null then
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (auth.uid(), 'bill_change', 'bill_change:' || gen_random_uuid(),
            jsonb_build_object('from', b.plan, 'to', coalesce(b.next_plan, b.plan),
              'fromPeriod', b.period, 'toPeriod', coalesce(b.next_period, b.period), 'on', b.next_billing_date,
              'nextAmount', case when coalesce(b.next_plan, b.plan) <> 'free' then public.billing_amount_due(auth.uid()) end,
              'removePlants', coalesce((select jsonb_agg(pu.plant_name order by pu.linked_at) from public.plant_users pu
                                         where pu.user_id = auth.uid() and pu.plant_id = any (b.plants_to_remove)), '[]'::jsonb)),
            1);
  end if;
  return public.api_billing_status();
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'billing_charge_open(uuid, text, text, int)', 'billing_settle_open(uuid)',
    'billing_charge_paid(text, jsonb, boolean, bigint)', 'billing_charge_failed(text, text)', 'billing_run(date)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
revoke all on function private.billing_resume(uuid, text, int), private.billing_to_free(uuid, date),
  private.billing_drop_plant(uuid, bigint) from public, anon, authenticated;

-- Daily at 06:00 South African time (04:00 UTC): renewals are charged in the morning.
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
  perform cron.schedule('billing-run', '0 4 * * *', format($job$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
        'Content-Type', 'application/json'),
      body := '{}'::jsonb,
      timeout_milliseconds := 120000);
  $job$, fn_url));
end $$;
