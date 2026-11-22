-- ============================================================================
-- 0245 — billing redesign phase 2: payment commands and the daily job (SOLAR-641).
--
-- Every command takes `at` (tests move the clock), locks the account row, then
-- plants by id, bumps accounts.version when the account changes, and logs one
-- account_events row. Paystack is never called from here: the billing function
-- calls Paystack and reports each answer to apply_payment / record_*.
--
-- Buying
--   start_checkout(account, plan, interval, extras, plants)  no running plan.
--       A bill with the final plant choice and accounts.version bound to it. The
--       launch offer applies to first-time members. Does not bump the version: two
--       tabs get bills with the same version, the first paid applies, the second is
--       refunded as stale.
--   upgrade(account, plan, extras, plants)  active only (blocked while past_due).
--       The difference for the days left, counted in the market's time zone,
--       rounded to the cent; below Paystack's minimum it is waived and applied at
--       once. Billing day stays. The offer stays. Clears a booked downgrade.
--   downgrade(account, plan, extras, drop)  booked for the next billing date; the
--       plants to drop must be named so the rest fit. Same plan and places: undo.
--   switch_interval(account, interval)  booked for the next billing date.
--   cancel / undo_cancel                runs to period_end, then ends.
--   pay_now(account)                    the open renewal bill, to charge now.
--   start_card_check(account)           Paystack's minimum on a new card, refunded.
--   begin_attempt(invoice, channel)     writes a try with its own reference and a
--       lease before any charge call. Unresolved tries are verified first.
--   apply_payment(reference, tx)        every Paystack answer (charge reply, verify,
--       webhook). Checks reference, status, amount and currency against the try.
--       Stale (version moved), duplicate (bill already paid or void), unknown or
--       deleted account and wrong amount: not applied, refunded.
--   record_refund / record_refund_event / record_dispute
--   event_begin / event_done            webhook dedupe on (provider, type, entity, status).
--   delete_account(account)             only none/trialing/ended, nothing owed, no
--       open dispute. Payment rows stay, account reference cleared.
--
-- Daily job: run(at). Advisory lock. One step per subscription per call:
--   booked cancel reached -> ended at period_end;
--   past_due past the last retry -> ended on day max(retry_days) + 1;
--   renewal due -> the bill for the next period (unique) and one try: day 0, then
--   the latest retry day reached that has no try yet (missed days never fire
--   together). No usable card on day 0 -> a recorded failed try (past_due starts).
--   Hard declines switch the card off, so no retries follow.
--   Also returns tries to verify (lease ran out) and refunds to send or resend.
-- Month ends: the next period_end is billing_day clamped to that month's last day,
-- in the market's time zone (31 Jan -> 28/29 Feb -> 31 Mar).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create function billing.add_period(p_from timestamptz, p_interval text, p_billing_day int, p_tz text)
returns timestamptz language plpgsql immutable set search_path = billing, pg_temp as $$
declare
  l timestamp := p_from at time zone p_tz;
  m date := (date_trunc('month', l) + case p_interval when 'year' then interval '1 year' else interval '1 month' end)::date;
  last_day int := extract(day from (m + interval '1 month - 1 day'))::int;
begin
  return ((m + (least(p_billing_day, last_day) - 1)) + l::time) at time zone p_tz;
end $$;

create function billing.new_reference()
returns text language sql volatile as $$ select 'psh_' || replace(gen_random_uuid()::text, '-', '') $$;

create function billing.price_for(p_plan text, p_market text, p_interval text, p_offer text, p_at timestamptz)
returns billing.prices language sql stable set search_path = billing, pg_temp as $$
  select * from billing.prices
   where plan = p_plan and market = p_market and interval = p_interval and offer is not distinct from p_offer
     and active_from <= p_at and (active_until is null or active_until > p_at)
   order by active_from desc limit 1
$$;

-- The price a running plan moves to: its own offer's price while the offer has one, else list.
create function billing.price_keeping_offer(p_plan text, p_market text, p_interval text, p_offer text, p_at timestamptz)
returns billing.prices language plpgsql stable set search_path = billing, pg_temp as $$
declare pr billing.prices;
begin
  if p_offer is not null then pr := billing.price_for(p_plan, p_market, p_interval, p_offer, p_at); end if;
  if pr.id is null then pr := billing.price_for(p_plan, p_market, p_interval, null, p_at); end if;
  if pr.id is null then raise exception 'no price for % %', p_plan, p_interval using errcode = '22023'; end if;
  return pr;
end $$;

-- The offer a new purchase gets: open, first-time rule met, places left. A place is
-- held by a member, or by another account's open checkout on the offer for an hour
-- (longer while its payment is unanswered). start_checkout locks the offer rows first,
-- so two checkouts cannot take the last place.
create function billing.offer_for(p_account uuid, p_at timestamptz)
returns text language sql stable set search_path = billing, pg_temp as $$
  select o.code from billing.offers o
   where o.valid_from <= p_at and (o.valid_until is null or o.valid_until > p_at)
     and (not o.first_time_only or not exists (select 1 from billing.subscriptions s where s.account = p_account))
     and (o.max_members is null
          or (select count(*) from (
                select s.account from billing.subscriptions s where s.offer = o.code and s.account <> p_account
                union
                select i.account from billing.invoices i
                 where i.offer = o.code and i.kind = 'purchase' and i.status = 'open' and i.account <> p_account
                   and i.created_at <= p_at
                   and (i.created_at > p_at - interval '1 hour'
                        or exists (select 1 from billing.payment_attempts pa where pa.invoice = i.id
                                      and pa.status in ('created', 'pending', 'unknown')))) x) < o.max_members)
   order by o.valid_from desc limit 1
$$;

-- A try on any open bill of the account that may still take money. An open card page
-- does not count: a new checkout replaces it (replace_card_pages), so closing the page and
-- trying again never waits for its hour. Paid anyway, that payment is stale and refunded.
create function billing.payment_in_flight(p_account uuid)
returns boolean language sql stable set search_path = billing, pg_temp as $$
  select exists (select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
                  where i.account = p_account and i.status = 'open' and pa.status in ('created', 'pending', 'unknown')
                    and not (pa.channel = 'card_page' and pa.status = 'pending'))
$$;

-- The open card pages on these bills are let go: a new bill or a new page replaces them.
create function billing.replace_card_pages(p_invoices uuid[], p_at timestamptz)
returns void language sql set search_path = billing, pg_temp as $$
  update billing.payment_attempts set status = 'void', gateway_response = 'replaced', settled_at = p_at, claimed_until = null
   where invoice = any (p_invoices) and channel = 'card_page' and status = 'pending'
$$;

-- The email to charge a saved card with: the one it was saved under, else the sign-in email.
create function billing.charge_email(p_auth_email text, p_account uuid)
returns text language sql stable set search_path = billing, pg_temp as $$
  select coalesce(p_auth_email, (select u.email from billing.accounts a join auth.users u on u.id = a.user_id
                                   where a.id = p_account))
$$;

-- Paystack's paid_at when it is a time between the try and now; else now.
create function billing.paid_time(p_tx jsonb, p_created timestamptz, p_at timestamptz)
returns timestamptz language plpgsql stable set search_path = billing, pg_temp as $$
declare t timestamptz;
begin
  begin
    t := coalesce(p_tx->>'paid_at', p_tx->>'paidAt')::timestamptz;
  exception when others then
    t := null;
  end;
  if t is null or t > p_at or t < p_created - interval '5 minutes' then return p_at; end if;
  return t;
end $$;

create function billing.grant_places(p_account uuid, p_at timestamptz)
returns int language sql stable set search_path = billing, pg_temp as $$
  select coalesce(sum(places), 0)::int from billing.grants
   where account = p_account and starts_at <= p_at and (ends_at is null or ends_at > p_at)
$$;

-- The final plant choice for a bill: required, each reachable, fits the places.
create function billing.final_choice(p_account uuid, p_plants bigint[], p_places int)
returns bigint[] language plpgsql stable set search_path = billing, pg_temp as $$
declare want bigint[]; bad bigint;
begin
  if p_plants is null then raise exception 'choose the plants first' using errcode = '22023'; end if;
  want := array(select distinct x from unnest(p_plants) x order by 1);
  select x into bad from unnest(want) x where not billing.has_route(p_account, x, false) limit 1;
  if found then raise exception 'plant % is not on this account''s logins', bad using errcode = '22023'; end if;
  if cardinality(want) > p_places then
    raise exception 'that plan has % places', p_places using errcode = '22023';
  end if;
  return want;
end $$;

create function billing.active_method(p_account uuid)
returns billing.payment_methods language sql stable set search_path = billing, pg_temp as $$
  select * from billing.payment_methods where account = p_account and active
$$;

create function billing.invoice_out(p_inv billing.invoices)
returns jsonb language sql stable set search_path = billing, pg_temp as $$
  select jsonb_build_object('invoice', p_inv.id, 'kind', p_inv.kind, 'status', p_inv.status,
                            'amount_minor', p_inv.amount_minor, 'currency', p_inv.currency,
                            'saved_card', p_inv.account is not null and exists
                              (select 1 from billing.payment_methods pm where pm.account = p_inv.account and pm.active))
$$;

create function billing.bump(p_account uuid)
returns void language sql set search_path = billing, pg_temp as $$
  update billing.accounts set version = version + 1 where id = p_account
$$;

create function billing.live_sub(p_account uuid)
returns billing.subscriptions language sql stable set search_path = billing, pg_temp as $$
  select * from billing.subscriptions where account = p_account and status in ('active', 'past_due')
$$;

-- Ends a running plan: open bills voided, version bumped, logged. p_bump false: the
-- clock had ended it already (the job catching up), so a checkout made meanwhile stays good.
create function billing.end_sub(p_sub uuid, p_ended_at timestamptz, p_reason text, p_at timestamptz, p_actor text,
                                p_bump boolean default true)
returns void language plpgsql set search_path = billing, pg_temp as $$
declare s billing.subscriptions;
begin
  update billing.subscriptions set status = 'ended', ended_at = p_ended_at, past_due_since = null, version = version + 1
   where id = p_sub and status in ('active', 'past_due') returning * into s;
  if not found then return; end if;
  update billing.invoices set status = 'void' where subscription = p_sub and status = 'open';
  if p_bump then perform billing.bump(s.account); end if;
  perform billing.log_event(s.account, p_at, p_actor, 'plan_ended', null,
                            jsonb_build_object('sub', p_sub, 'ended_at', p_ended_at), p_reason);
end $$;

-- The renewal bill for the period after s.period_end, made once. Booked changes
-- (next_price, next_extra_places) are frozen into it.
create function billing.ensure_renewal(p_sub uuid, p_at timestamptz)
returns billing.invoices language plpgsql set search_path = billing, pg_temp as $$
declare
  s billing.subscriptions;
  m billing.markets;
  np billing.prices;
  inv billing.invoices;
  key text;
  iv text;
  extras int;
begin
  select * into s from billing.subscriptions where id = p_sub;
  select mk.* into m from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = s.account;
  key := extract(epoch from s.period_end)::bigint::text;
  select * into inv from billing.invoices
   where subscription = p_sub and kind = 'renewal' and period_key = key and status <> 'void';
  if found then return inv; end if;
  if s.next_price is not null then select * into np from billing.prices where id = s.next_price; end if;
  iv := coalesce(np.interval, s.interval);
  extras := coalesce(s.next_extra_places, s.extra_places);
  insert into billing.invoices (account, subscription, kind, price, plan, interval, offer, extra_places,
                                plan_amount_minor, extra_place_minor, amount_minor, tax_minor, currency,
                                period_start, period_end, period_key, created_at)
  values (s.account, s.id, 'renewal', coalesce(np.id, s.price), coalesce(np.plan, s.plan), iv, s.offer, extras,
          coalesce(np.amount_minor, s.amount_minor), coalesce(np.extra_place_minor, s.extra_place_minor),
          coalesce(np.amount_minor, s.amount_minor) + extras * coalesce(np.extra_place_minor, s.extra_place_minor),
          np.tax_minor, s.currency,
          s.period_end, billing.add_period(s.period_end, iv, s.billing_day, m.default_time_zone), key, p_at)
  returning * into inv;
  return inv;
end $$;

-- ---------------------------------------------------------------------------
-- start_checkout: a first purchase or a restart.
-- ---------------------------------------------------------------------------
create function billing.start_checkout(p_account uuid, p_plan text, p_interval text, p_extra_places int,
                                       p_plants bigint[], p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  a billing.accounts;
  m billing.markets;
  st billing.status;
  pl billing.plans;
  pr billing.prices;
  off text;
  extras int := coalesce(p_extra_places, 0);
  want bigint[];
  inv billing.invoices;
begin
  a := billing.lock_account(p_account);
  perform 1 from billing.offers order by code for update;      -- the last offer place goes to one checkout
  select * into m from billing.markets where code = a.market;
  st := billing.account_status(p_account, p_at);
  if st.sub is not null then raise exception 'a plan is already running' using errcode = '22023'; end if;
  select * into pl from billing.plans where code = p_plan;
  if not found then raise exception 'no such plan' using errcode = '22023'; end if;
  if p_interval is null or p_interval not in ('month', 'year') then
    raise exception 'monthly or yearly' using errcode = '22023';
  end if;
  if extras < 0 or (extras > 0 and not pl.allows_extra) then
    raise exception 'extra places are not sold on %', pl.name using errcode = '22023';
  end if;
  off := billing.offer_for(p_account, p_at);
  if off is not null then pr := billing.price_for(p_plan, a.market, p_interval, off, p_at); end if;
  if pr.id is null then
    off := null;
    pr := billing.price_for(p_plan, a.market, p_interval, null, p_at);
  end if;
  if pr.id is null then raise exception 'no price for % %', p_plan, p_interval using errcode = '22023'; end if;

  want := billing.final_choice(p_account, p_plants, pl.places + extras + billing.grant_places(p_account, p_at));
  -- one open purchase bill per account: the same checkout again gets the same bill; another
  -- one replaces it, unless a payment on it may still take money
  select * into inv from billing.invoices
   where account = p_account and kind = 'purchase' and status = 'open' order by created_at desc limit 1;
  if inv.id is not null then
    if inv.price = pr.id and inv.offer is not distinct from off and inv.extra_places = extras and inv.plants = want
       and inv.expected_version = a.version then
      return billing.invoice_out(inv);
    end if;
    if billing.payment_in_flight(p_account) then
      raise exception 'a payment is already in progress' using errcode = '22023';
    end if;
    perform billing.replace_card_pages(array(select id from billing.invoices
                                              where account = p_account and kind = 'purchase' and status = 'open'), p_at);
    update billing.invoices set status = 'void' where account = p_account and kind = 'purchase' and status = 'open';
  end if;
  insert into billing.invoices (account, kind, price, plan, interval, offer, extra_places, plan_amount_minor,
                                extra_place_minor, amount_minor, tax_minor, currency, expected_version, plants, created_at)
  values (p_account, 'purchase', pr.id, p_plan, p_interval, off, extras, pr.amount_minor, pr.extra_place_minor,
          pr.amount_minor + extras * pr.extra_place_minor, pr.tax_minor, m.currency, a.version, want, p_at)
  returning * into inv;
  perform billing.log_event(p_account, p_at, p_actor, 'start_checkout', jsonb_build_object('state', st.state),
                            jsonb_build_object('invoice', inv.id, 'plan', p_plan, 'interval', p_interval,
                                               'extras', extras, 'offer', off, 'plants', to_jsonb(want)));
  return billing.invoice_out(inv);
end $$;

-- ---------------------------------------------------------------------------
-- Applying a paid bill (callers hold the account lock).
-- ---------------------------------------------------------------------------
create function billing.apply_purchase(p_inv billing.invoices, p_at timestamptz)
returns void language plpgsql set search_path = billing, pg_temp as $$
declare
  m billing.markets;
  sid uuid;
  day int;
  pe timestamptz;
  had bigint[];
begin
  select mk.* into m from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = p_inv.account;
  day := extract(day from p_at at time zone m.default_time_zone)::int;
  pe := billing.add_period(p_at, p_inv.interval, day, m.default_time_zone);
  insert into billing.subscriptions (account, price, plan, currency, interval, amount_minor, extra_place_minor,
                                     extra_places, offer, status, started_at, billing_day, period_start, period_end)
  values (p_inv.account, p_inv.price, p_inv.plan, p_inv.currency, p_inv.interval, p_inv.plan_amount_minor,
          p_inv.extra_place_minor, p_inv.extra_places, p_inv.offer, 'active', p_at, day, p_at, pe)
  returning id into sid;
  update billing.invoices set subscription = sid, period_start = p_at, period_end = pe where id = p_inv.id;
  -- paying in the free week ends the week and starts billing that day
  update billing.accounts set trial_ends_at = least(trial_ends_at, p_at)
   where id = p_inv.account and trial_started_at is not null;
  had := array(select plant from billing.seats where account = p_inv.account and closed_at is null);
  perform billing.lock_plants(p_inv.plants || had);
  perform billing.write_seats(p_inv.account, p_inv.plants, p_at);
end $$;

create function billing.apply_renewal(p_inv billing.invoices, p_at timestamptz)
returns void language plpgsql set search_path = billing, pg_temp as $$
declare dropped bigint[];
begin
  update billing.subscriptions
     set status = 'active', past_due_since = null, ended_at = null, price = p_inv.price, plan = p_inv.plan, interval = p_inv.interval,
         amount_minor = p_inv.plan_amount_minor, extra_place_minor = p_inv.extra_place_minor,
         extra_places = p_inv.extra_places, period_start = p_inv.period_start, period_end = p_inv.period_end,
         next_price = null, next_extra_places = null, version = version + 1
   where id = p_inv.subscription;
  -- a booked downgrade: the plants picked to drop go now
  dropped := array(select plant from billing.seats
                    where account = p_inv.account and closed_at is null and drop_at_period_end order by plant);
  if cardinality(dropped) > 0 then
    perform billing.lock_plants(dropped);
    update billing.seats set closed_at = p_at, close_reason = 'dropped', drop_at_period_end = false
     where account = p_inv.account and closed_at is null and drop_at_period_end;
    update billing.plants set version = version + 1 where id = any (dropped);
  end if;
end $$;

create function billing.apply_upgrade(p_inv billing.invoices, p_at timestamptz)
returns void language plpgsql set search_path = billing, pg_temp as $$
declare
  s billing.subscriptions;
  a billing.accounts;
  np billing.prices;
  had bigint[];
begin
  select * into s from billing.subscriptions where id = p_inv.subscription;
  select * into a from billing.accounts where id = p_inv.account;
  -- a booked interval switch carries over to the new plan; a booked downgrade is cleared
  if s.next_price is not null then
    select * into np from billing.prices where id = s.next_price;
    if np.interval <> s.interval then
      np := billing.price_keeping_offer(p_inv.plan, a.market, np.interval, s.offer, p_at);
    else
      np := null;
    end if;
  end if;
  update billing.subscriptions
     set price = p_inv.price, plan = p_inv.plan, amount_minor = p_inv.plan_amount_minor,
         extra_place_minor = p_inv.extra_place_minor, extra_places = p_inv.extra_places,
         next_price = np.id, next_extra_places = null, version = version + 1
   where id = s.id;
  update billing.seats set drop_at_period_end = false where account = p_inv.account and closed_at is null and drop_at_period_end;
  had := array(select plant from billing.seats where account = p_inv.account and closed_at is null);
  perform billing.lock_plants(p_inv.plants || had);
  perform billing.write_seats(p_inv.account, p_inv.plants, p_at);
end $$;

-- ---------------------------------------------------------------------------
-- upgrade: more places now. Billing day stays; the offer stays.
-- ---------------------------------------------------------------------------
create function billing.upgrade(p_account uuid, p_plan text, p_extra_places int, p_plants bigint[],
                                p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  a billing.accounts;
  m billing.markets;
  st billing.status;
  s billing.subscriptions;
  pl billing.plans;
  pr billing.prices;
  extras int := coalesce(p_extra_places, 0);
  cur_places int;
  new_amt int;
  old_amt int;
  days_left int;
  days_all int;
  due int;
  want bigint[];
  inv billing.invoices;
begin
  a := billing.lock_account(p_account);
  select * into m from billing.markets where code = a.market;
  st := billing.account_status(p_account, p_at);
  if st.state = 'past_due' then raise exception 'pay the failed payment first' using errcode = '22023'; end if;
  if st.state <> 'active' or st.sub is null then raise exception 'no running plan' using errcode = '22023'; end if;
  select * into s from billing.subscriptions where id = st.sub for update;
  if s.period_end <= p_at then raise exception 'the renewal is due: pay it first' using errcode = '22023'; end if;
  select * into pl from billing.plans where code = p_plan;
  if not found then raise exception 'no such plan' using errcode = '22023'; end if;
  if extras < 0 or (extras > 0 and not pl.allows_extra) then
    raise exception 'extra places are not sold on %', pl.name using errcode = '22023';
  end if;
  cur_places := (select places from billing.plans where code = s.plan) + s.extra_places;
  if pl.places + extras <= cur_places then
    raise exception 'that is not more places' using errcode = '22023';
  end if;

  pr := billing.price_keeping_offer(p_plan, a.market, s.interval, s.offer, p_at);
  old_amt := s.amount_minor + s.extra_places * s.extra_place_minor;
  new_amt := pr.amount_minor + extras * pr.extra_place_minor;
  days_left := (s.period_end at time zone m.default_time_zone)::date - (p_at at time zone m.default_time_zone)::date;
  days_all := (s.period_end at time zone m.default_time_zone)::date - (s.period_start at time zone m.default_time_zone)::date;
  due := greatest(round((new_amt - old_amt)::numeric * days_left / greatest(days_all, 1)), 0)::int;
  want := billing.final_choice(p_account, p_plants, pl.places + extras + billing.grant_places(p_account, p_at));

  -- the same upgrade again (the card page closed, tried again): the same bill
  select * into inv from billing.invoices
   where subscription = s.id and kind = 'upgrade' and status = 'open' and plan = p_plan and extra_places = extras
     and plants = want and expected_version = a.version and period_start = s.period_start
   order by created_at desc limit 1;
  if inv.id is not null then return billing.invoice_out(inv) || jsonb_build_object('applied', false); end if;
  if billing.payment_in_flight(p_account) then
    raise exception 'a payment is already in progress' using errcode = '22023';
  end if;
  perform billing.replace_card_pages(array(select id from billing.invoices
                                            where subscription = s.id and kind = 'upgrade' and status = 'open'), p_at);
  update billing.invoices set status = 'void' where subscription = s.id and kind = 'upgrade' and status = 'open';
  insert into billing.invoices (account, subscription, kind, status, price, plan, interval, offer, extra_places,
                                plan_amount_minor, extra_place_minor, amount_minor, tax_minor, currency, period_start,
                                period_end, period_key, expected_version, plants, created_at)
  values (p_account, s.id, 'upgrade', case when due < m.min_charge_minor then 'waived' else 'open' end, pr.id, p_plan,
          s.interval, s.offer, extras, pr.amount_minor, pr.extra_place_minor, due, pr.tax_minor, s.currency,
          s.period_start, s.period_end, extract(epoch from s.period_start)::bigint || ':' || p_plan || '+' || extras,
          a.version, want, p_at)
  returning * into inv;
  perform billing.log_event(p_account, p_at, p_actor, 'upgrade',
                            jsonb_build_object('plan', s.plan, 'extras', s.extra_places),
                            jsonb_build_object('invoice', inv.id, 'plan', p_plan, 'extras', extras, 'due', due,
                                               'waived', inv.status = 'waived', 'plants', to_jsonb(want)));
  if inv.status = 'waived' then
    perform billing.apply_upgrade(inv, p_at);
    perform billing.bump(p_account);
    return billing.invoice_out(inv) || jsonb_build_object('applied', true);
  end if;
  return billing.invoice_out(inv) || jsonb_build_object('applied', false);
end $$;

-- ---------------------------------------------------------------------------
-- downgrade: fewer places from the next billing date. p_drop: the plants that go.
-- The same plan and places as now: the booking is undone.
-- ---------------------------------------------------------------------------
create function billing.downgrade(p_account uuid, p_plan text, p_extra_places int, p_drop bigint[],
                                  p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  a billing.accounts;
  st billing.status;
  s billing.subscriptions;
  pl billing.plans;
  pr billing.prices;
  np billing.prices;
  extras int := coalesce(p_extra_places, 0);
  cur_places int;
  new_places int;
  drop_ids bigint[];
  bad bigint;
  iv text;
begin
  a := billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state <> 'active' or st.sub is null then raise exception 'no running plan' using errcode = '22023'; end if;
  select * into s from billing.subscriptions where id = st.sub for update;
  if s.cancel_at_period_end then raise exception 'the plan is cancelled' using errcode = '22023'; end if;
  if s.period_end <= p_at then raise exception 'the renewal is due: pay it first' using errcode = '22023'; end if;
  select * into pl from billing.plans where code = p_plan;
  if not found then raise exception 'no such plan' using errcode = '22023'; end if;
  if extras < 0 or (extras > 0 and not pl.allows_extra) then
    raise exception 'extra places are not sold on %', pl.name using errcode = '22023';
  end if;
  cur_places := (select places from billing.plans where code = s.plan) + s.extra_places;
  new_places := pl.places + extras;
  if s.next_price is not null then select * into np from billing.prices where id = s.next_price; end if;
  iv := coalesce(np.interval, s.interval);

  if p_plan = s.plan and extras = s.extra_places then
    -- undo: keep a booked interval switch only
    update billing.subscriptions
       set next_price = case when iv <> s.interval then (billing.price_keeping_offer(s.plan, a.market, iv, s.offer, p_at)).id end,
           next_extra_places = null, version = version + 1
     where id = s.id;
    update billing.seats set drop_at_period_end = false where account = p_account and closed_at is null;
  else
    if new_places >= cur_places then raise exception 'that is not fewer places' using errcode = '22023'; end if;
    drop_ids := array(select distinct x from unnest(coalesce(p_drop, '{}')) x order by 1);
    select x into bad from unnest(drop_ids) x
     where not exists (select 1 from billing.seats se where se.account = p_account and se.plant = x and se.closed_at is null)
     limit 1;
    if found then raise exception 'plant % is not chosen', bad using errcode = '22023'; end if;
    if st.chosen - cardinality(drop_ids) > new_places + billing.grant_places(p_account, p_at) then
      raise exception 'pick % more plants to drop', st.chosen - cardinality(drop_ids) - new_places - billing.grant_places(p_account, p_at)
        using errcode = '22023';
    end if;
    pr := billing.price_keeping_offer(p_plan, a.market, iv, s.offer, p_at);
    update billing.subscriptions set next_price = pr.id, next_extra_places = extras, version = version + 1 where id = s.id;
    update billing.seats set drop_at_period_end = (plant = any (drop_ids)) where account = p_account and closed_at is null;
  end if;
  perform billing.bump(p_account);
  perform billing.log_event(p_account, p_at, p_actor, 'downgrade',
                            jsonb_build_object('plan', s.plan, 'extras', s.extra_places),
                            jsonb_build_object('plan', p_plan, 'extras', extras, 'drop', to_jsonb(drop_ids)));
  return billing.account_state(p_account, p_at);
end $$;

-- ---------------------------------------------------------------------------
-- switch_interval: monthly/yearly from the next billing date. Keeps a booked downgrade.
-- ---------------------------------------------------------------------------
create function billing.switch_interval(p_account uuid, p_interval text,
                                        p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  a billing.accounts;
  st billing.status;
  s billing.subscriptions;
  np billing.prices;
  plan text;
  nid uuid;
begin
  a := billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state <> 'active' or st.sub is null then raise exception 'no running plan' using errcode = '22023'; end if;
  if p_interval is null or p_interval not in ('month', 'year') then
    raise exception 'monthly or yearly' using errcode = '22023';
  end if;
  select * into s from billing.subscriptions where id = st.sub for update;
  if s.period_end <= p_at then raise exception 'the renewal is due: pay it first' using errcode = '22023'; end if;
  if s.next_price is not null then select * into np from billing.prices where id = s.next_price; end if;
  plan := coalesce(np.plan, s.plan);
  if p_interval = s.interval and plan = s.plan and s.next_extra_places is null then
    nid := null;
  else
    nid := (billing.price_keeping_offer(plan, a.market, p_interval, s.offer, p_at)).id;
  end if;
  update billing.subscriptions set next_price = nid, version = version + 1 where id = s.id;
  perform billing.bump(p_account);
  perform billing.log_event(p_account, p_at, p_actor, 'switch_interval',
                            jsonb_build_object('interval', s.interval), jsonb_build_object('interval', p_interval));
  return billing.account_state(p_account, p_at);
end $$;

-- ---------------------------------------------------------------------------
create function billing.cancel(p_account uuid, p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare st billing.status; s billing.subscriptions;
begin
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state <> 'active' or st.sub is null then raise exception 'no running plan to cancel' using errcode = '22023'; end if;
  update billing.subscriptions set cancel_at_period_end = true, version = version + 1
   where id = st.sub and not cancel_at_period_end returning * into s;
  if found then
    perform billing.bump(p_account);
    perform billing.log_event(p_account, p_at, p_actor, 'cancel', null, jsonb_build_object('ends', s.period_end));
  end if;
  return billing.account_state(p_account, p_at);
end $$;

create function billing.undo_cancel(p_account uuid, p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare st billing.status; s billing.subscriptions;
begin
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state <> 'active' or st.cancel_at is null then raise exception 'no cancel to undo' using errcode = '22023'; end if;
  update billing.subscriptions set cancel_at_period_end = false, version = version + 1 where id = st.sub returning * into s;
  perform billing.bump(p_account);
  perform billing.log_event(p_account, p_at, p_actor, 'undo_cancel', null, jsonb_build_object('next_charge', s.period_end));
  return billing.account_state(p_account, p_at);
end $$;

-- ---------------------------------------------------------------------------
-- pay_now: the open renewal bill (past_due, or due and not tried yet).
-- ---------------------------------------------------------------------------
create function billing.pay_now(p_account uuid, p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare st billing.status; s billing.subscriptions;
begin
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.sub is null or st.state not in ('active', 'past_due') then raise exception 'nothing to pay' using errcode = '22023'; end if;
  select * into s from billing.subscriptions where id = st.sub;
  if s.period_end > p_at then raise exception 'nothing to pay' using errcode = '22023'; end if;
  return billing.invoice_out(billing.ensure_renewal(s.id, p_at));
end $$;

-- A new card. While a renewal is owed (past due, or due and not tried) the new card pays
-- that bill instead of the R1 check: the card is saved with the payment.
create function billing.start_card_check(p_account uuid, p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare a billing.accounts; m billing.markets; inv billing.invoices; st billing.status;
begin
  a := billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.sub is not null and st.state in ('active', 'past_due')
     and (select period_end from billing.subscriptions where id = st.sub) <= p_at then
    return billing.invoice_out(billing.ensure_renewal(st.sub, p_at));
  end if;
  select * into m from billing.markets where code = a.market;
  insert into billing.invoices (account, kind, amount_minor, currency, created_at)
  values (p_account, 'card_check', m.min_charge_minor, m.currency, p_at) returning * into inv;
  return billing.invoice_out(inv);
end $$;

-- ---------------------------------------------------------------------------
-- begin_attempt: a try with its own reference, written before the charge call.
-- saved_card: the lease (10 min) stops a second charge. card_page: the page is
-- open for an hour; asked again for the same bill inside that hour, the same page
-- comes back ({url}, stored by attempt_page), so closing it and trying again lands
-- on it. Abandoned (Paystack) or the hour gone: a new page. Returns {busy} while
-- another try holds its lease, or {verify: [references]} for tries to check first.
-- ---------------------------------------------------------------------------
create function billing.begin_attempt(p_invoice uuid, p_channel text, p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  inv billing.invoices;
  pm billing.payment_methods;
  att billing.payment_attempts;
  stale jsonb;
begin
  select * into inv from billing.invoices where id = p_invoice;
  if not found or inv.account is null then raise exception 'no such bill' using errcode = 'P0002'; end if;
  perform billing.lock_account(inv.account);
  select * into inv from billing.invoices where id = p_invoice for update;
  if inv.status <> 'open' then raise exception 'this bill is %', inv.status using errcode = '22023'; end if;
  if p_channel not in ('saved_card', 'card_page') then raise exception 'bad channel' using errcode = '22023'; end if;
  -- the bill's plants and the account's seats, so the delete job cannot purge them under a
  -- payment that is starting (it skips a plant held by a try: payment_hold)
  perform billing.lock_plants(coalesce(inv.plants, '{}')
                              || array(select plant from billing.seats where account = inv.account and closed_at is null));

  if p_channel = 'card_page' then
    select * into att from billing.payment_attempts
     where invoice = p_invoice and channel = 'card_page' and status = 'pending' and pay_url is not null
       and claimed_until > p_at
     order by created_at desc limit 1;
    if found then
      return jsonb_build_object('reference', att.reference, 'invoice', inv.id, 'kind', inv.kind,
                                'amount_minor', att.amount_minor, 'currency', att.currency, 'url', att.pay_url);
    end if;
  end if;

  -- any open bill of the account: a try there may still take money
  select jsonb_agg(pa.reference order by pa.created_at) into stale
    from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
   where i.account = inv.account and i.status = 'open' and pa.status in ('created', 'pending', 'unknown')
     and pa.claimed_until <= p_at;
  if stale is not null then return jsonb_build_object('verify', stale); end if;
  if billing.payment_in_flight(inv.account) then return jsonb_build_object('busy', true); end if;

  if p_channel = 'saved_card' then
    pm := billing.active_method(inv.account);
    if pm.id is null then raise exception 'no saved card' using errcode = 'P0002'; end if;
  end if;
  perform billing.replace_card_pages(array[p_invoice], p_at);
  insert into billing.payment_attempts (invoice, reference, provider, channel, payment_method, amount_minor, currency,
                                        status, claimed_until, created_at)
  values (p_invoice, billing.new_reference(), 'paystack', p_channel, pm.id, inv.amount_minor, inv.currency,
          case p_channel when 'saved_card' then 'created' else 'pending' end,
          p_at + case p_channel when 'saved_card' then interval '10 minutes' else interval '1 hour' end, p_at)
  returning * into att;
  return jsonb_build_object('reference', att.reference, 'invoice', inv.id, 'kind', inv.kind,
                            'amount_minor', att.amount_minor, 'currency', att.currency,
                            'auth_ref', pm.auth_ref,
                            'auth_email', case when pm.id is not null then billing.charge_email(pm.auth_email, inv.account) end);
end $$;

-- The card page Paystack opened for a try, so the same page can be handed back.
create function billing.attempt_page(p_reference text, p_url text)
returns jsonb language sql security definer set search_path = billing, pg_temp as $$
  update billing.payment_attempts set pay_url = p_url
   where reference = p_reference and channel = 'card_page' and status = 'pending' and p_url like 'https://%'
  returning jsonb_build_object('reference', reference)
$$;

-- Saves the card Paystack answered with; a reusable one becomes the account's active card.
create function billing.save_method(p_account uuid, p_tx jsonb, p_at timestamptz)
returns uuid language plpgsql set search_path = billing, pg_temp as $$
declare
  au jsonb := p_tx->'authorization';
  reusable boolean := coalesce((p_tx->'authorization'->>'reusable')::boolean, false);
  pm_id uuid;
begin
  if p_account is null or au is null or au->>'authorization_code' is null then return null; end if;
  insert into billing.payment_methods (account, provider, customer_code, auth_ref, auth_email, reusable, signature,
                                       card_type, last4, exp_month, exp_year, active, disabled_reason, created_at)
  values (p_account, 'paystack', p_tx->'customer'->>'customer_code', au->>'authorization_code', p_tx->'customer'->>'email',
          reusable, au->>'signature', au->>'card_type', au->>'last4', nullif(au->>'exp_month', '')::smallint,
          nullif(au->>'exp_year', '')::smallint, false, case when reusable then 'replaced' else 'not_reusable' end, p_at)
  on conflict (provider, auth_ref) do update
     set auth_email = coalesce(excluded.auth_email, payment_methods.auth_email),
         customer_code = coalesce(excluded.customer_code, payment_methods.customer_code)
  returning payment_methods.id into pm_id;
  if reusable then
    update billing.payment_methods set active = false, disabled_reason = 'replaced'
     where account = p_account and active and payment_methods.id <> pm_id;
    update billing.payment_methods set active = true, disabled_reason = null, account = p_account
     where payment_methods.id = pm_id;
  end if;
  return pm_id;
end $$;

-- A refund owed on a payment; one automatic refund per transaction.
create function billing.refund_due(p_attempt uuid, p_reference text, p_account uuid, p_currency text,
                                   p_reason text, p_at timestamptz)
returns uuid language plpgsql set search_path = billing, pg_temp as $$
declare rid uuid;
begin
  insert into billing.refunds (attempt, reference, account, currency, reason, status, created_at, updated_at)
  values (p_attempt, p_reference, p_account, p_currency, p_reason, 'due', p_at, p_at)
  on conflict (reference) where reason <> 'manual' do nothing
  returning refunds.id into rid;
  if rid is null then select r.id into rid from billing.refunds r where r.reference = p_reference and r.reason <> 'manual'; end if;
  return rid;
end $$;

-- Paystack's gateway words for a card that will never work again.
create function billing.is_hard_decline(p_msg text)
returns boolean language sql immutable as $$
  select coalesce(p_msg ~* '(stolen|lost card|pick ?up|restricted card|expired|closed|invalid card|no such card|not reusable|invalid authorization|authorization.*(invalid|not found)|card.*(blocked|deactivated))', false)
$$;

-- ---------------------------------------------------------------------------
-- Money given back after a payment was applied (a reversal, a lost dispute).
-- The current period of a plan that still runs by the clock: the plan ends now and
-- that card goes off. Anything else (an old period, a plan already over): owed on that bill.
-- ---------------------------------------------------------------------------
create function billing.money_back(p_att billing.payment_attempts, p_inv billing.invoices, p_amount int,
                                   p_reason text, p_at timestamptz)
returns jsonb language plpgsql set search_path = billing, pg_temp as $$
declare
  s billing.subscriptions;
  owed int := coalesce(p_amount, p_att.amount_minor);
begin
  if p_inv.account is null or p_inv.kind = 'card_check' then return jsonb_build_object('action', 'recorded'); end if;
  if p_inv.subscription is not null then
    select * into s from billing.subscriptions where id = p_inv.subscription for update;
  end if;
  if s.id is not null and (billing.account_status(p_inv.account, p_at)).sub = s.id
     and p_inv.period_start = s.period_start then
    perform billing.end_sub(s.id, p_at, p_reason, p_at, 'paystack');
    update billing.payment_methods set active = false,
                                       disabled_reason = case when p_reason = 'reversed' then 'reversed' else 'dispute' end
     where id = p_att.payment_method and active;
    return jsonb_build_object('action', 'plan_ended');
  end if;
  update billing.invoices set amount_owed_minor = owed where id = p_inv.id;
  perform billing.bump(p_inv.account);
  perform billing.log_event(p_inv.account, p_at, 'paystack', 'money_owed', null,
                            jsonb_build_object('invoice', p_inv.id, 'amount', owed), p_reason);
  return jsonb_build_object('action', 'owed', 'amount_minor', owed);
end $$;

-- ---------------------------------------------------------------------------
-- apply_payment: every Paystack answer about one of our references.
--   tx.status success                 -> checked, then applied or refunded. Applies only
--                                        when the answer names this exact reference.
--                                        Dated by Paystack's paid_at (checked), so a
--                                        payment made before day 15 whose answer comes
--                                        after it still counts.
--   reversed on a paid try            -> recorded against that try; the money is back
--                                        with the owner (money_back)
--   failed / reversed                 -> a failed try
--   abandoned                         -> the owner left the card page: void, not a decline
--   not_found                         -> the try never reached Paystack: void
--   unknown                           -> no clear answer: verify before any new try
--   anything else (pending, paused, send_otp, ongoing, open_url, ...)
--                                     -> pending; a bank challenge keeps its pay link
-- A failed or unanswered renewal starts the unpaid window from the bill's due date.
-- Returns {action: applied | again | refund | failed | void | unknown | pending | ignored |
--          plan_ended | owed}.
-- ---------------------------------------------------------------------------
create function billing.apply_payment(p_reference text, p_tx jsonb, p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
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
  select * into att from billing.payment_attempts where reference = p_reference;
  if not found then
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
  -- still open 24 hours after the try, by Paystack's own answer: a failed try, no lease
  if txs not in ('success', 'abandoned', 'not_found', 'failed', 'reversed', 'unknown')
     and att.created_at <= p_at - interval '24 hours' then
    txs := 'failed';
    msg := 'still pending after 24 hours';
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
      when inv.status = 'paid' then 'duplicate'
      when inv.status <> 'open' and not revive then 'stale'
      when inv.kind in ('purchase', 'upgrade') and inv.expected_version is distinct from a.version then 'stale'
      -- the clock wins: a plan past its cancel date or day 15 is over even if the job has not run
      when inv.kind = 'purchase' and (billing.account_status(a.id, paid)).sub is not null then 'stale'
      when revive then null
      when inv.kind in ('upgrade', 'renewal') and (s.id is null or s.status not in ('active', 'past_due')) then 'stale'
      when inv.kind in ('upgrade', 'renewal') and (billing.account_status(a.id, paid)).sub is distinct from s.id then 'stale'
      when inv.kind = 'upgrade' and (s.period_start <> inv.period_start or inv.period_end <= paid or inv.period_end <= p_at
             or exists (select 1 from billing.invoices x where x.subscription = s.id and x.kind = 'renewal'
                           and x.status <> 'void' and x.period_start >= inv.period_end)) then 'stale'
      when inv.kind = 'renewal' and s.period_end <> inv.period_start then 'duplicate'
    end;
    if why is not null then
      update billing.payment_attempts set status = 'not_applied', settled_at = p_at, claimed_until = null,
                                          gateway_response = msg where id = att.id;
      rid := billing.refund_due(att.id, att.reference, a.id, att.currency, why, p_at);
      if a.id is not null then
        perform billing.log_event(a.id, p_at, 'paystack', 'payment_refunded', null,
                                  jsonb_build_object('invoice', inv.id, 'reference', att.reference), why);
      end if;
      return jsonb_build_object('action', 'refund', 'refund', rid, 'reason', why, 'kind', inv.kind);
    end if;

    pm := billing.save_method(a.id, p_tx, p_at);
    update billing.payment_attempts set status = 'success', settled_at = paid, claimed_until = null,
                                        payment_method = coalesce(pm, payment_method), gateway_response = msg
     where id = att.id;
    update billing.invoices set status = 'paid', paid_at = paid where id = inv.id returning * into inv;
    case inv.kind
      when 'purchase' then perform billing.apply_purchase(inv, paid);
      when 'renewal' then perform billing.apply_renewal(inv, paid);
      when 'upgrade' then perform billing.apply_upgrade(inv, paid);
      else rid := billing.refund_due(att.id, att.reference, a.id, att.currency, 'card_check', p_at);
    end case;
    perform billing.bump(a.id);
    perform billing.log_event(a.id, p_at, 'paystack', 'payment_applied', null,
                              jsonb_build_object('invoice', inv.id, 'kind', inv.kind, 'amount', att.amount_minor,
                                                 'reference', att.reference, 'paid_at', paid, 'revived', revive));
    return jsonb_build_object('action', 'applied', 'kind', inv.kind, 'refund', rid);
  end if;

  if txs in ('abandoned', 'not_found') then
    if att.status in ('created', 'pending', 'unknown') then
      update billing.payment_attempts set status = 'void', gateway_response = msg, settled_at = p_at, claimed_until = null
       where id = att.id;
    end if;
    return jsonb_build_object('action', 'void', 'kind', inv.kind);
  end if;

  if txs in ('failed', 'reversed') then
    if att.status = 'failed' then return jsonb_build_object('action', 'again', 'status', 'failed', 'kind', inv.kind); end if;
    hard := txs = 'failed' and billing.is_hard_decline(msg);
    update billing.payment_attempts set status = 'failed', hard_decline = hard, gateway_response = msg,
                                        settled_at = p_at, claimed_until = null
     where id = att.id;
    if hard and att.payment_method is not null then
      update billing.payment_methods set active = false, disabled_reason = 'hard_decline'
       where id = att.payment_method and active;
    end if;
    -- a card that will never work again on a charge the owner did not watch: ask for a new one
    if hard and a.id is not null and att.channel = 'saved_card' then
      insert into billing.outbox (account, key, invoice, dedupe_key, not_before, created_at)
      values (a.id, 'card_update', inv.id, 'card_update:' || inv.id, p_at, p_at)
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
      update billing.payment_attempts set status = 'unknown', gateway_response = msg, claimed_until = p_at + interval '10 minutes'
       where id = att.id;
    end if;
    return jsonb_build_object('action', 'unknown');
  end if;

  -- still open: card page, bank challenge, processing. The daily job lets it go after 24 hours.
  update billing.payment_attempts
     set status = 'pending', gateway_response = msg, claimed_until = p_at + interval '1 hour',
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
end $$;

-- ---------------------------------------------------------------------------
-- Refunds
-- ---------------------------------------------------------------------------
-- After POST /refund. p_error null: accepted (pending until Paystack's refund.processed).
-- Paystack's "already exist": treated as accepted. Anything else: failed, retried in an hour.
create function billing.record_refund(p_refund uuid, p_error text, p_provider_id text, p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare r billing.refunds;
begin
  update billing.refunds
     set status = case when p_error is null or p_error ~* 'already' then 'pending' else 'failed' end,
         last_error = p_error, provider_refund_id = coalesce(p_provider_id, provider_refund_id),
         claimed_until = null,
         next_try_at = case when p_error is null or p_error ~* 'already' then null else p_at + interval '1 hour' end,
         updated_at = p_at
   where id = p_refund and status in ('due', 'sending', 'failed')
  returning * into r;
  return to_jsonb(r);
end $$;

-- refund.pending / .processing / .processed / .failed from the webhook. A refund made
-- by hand in the dashboard is recorded as 'manual' against the original try.
-- p_provider_id: Paystack's refund id when the event has one (else null: matched on the
-- payment's reference); p_provider_ref: its refund_reference, kept when there is no id.
create function billing.record_refund_event(p_reference text, p_status text, p_provider_id text, p_amount int,
                                            p_reason text, p_at timestamptz default now(), p_provider_ref text default null)
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  st text := case lower(p_status) when 'processed' then 'processed' when 'failed' then 'failed'
                                  when 'needs-attention' then 'failed' else 'pending' end;
  r billing.refunds;
  att billing.payment_attempts;
  acc uuid;
begin
  -- events arrive out of order: processed is final, and a late pending does not undo failed
  update billing.refunds
     set status = case when status = 'processed' or (st = 'pending' and status = 'failed') then status else st end,
         provider_refund_id = coalesce(provider_refund_id, p_provider_id, p_provider_ref),
         amount_minor = coalesce(amount_minor, p_amount),
         last_error = case when st = 'failed' and status <> 'processed' then p_reason else last_error end,
         next_try_at = case when status = 'processed' then null
                            when st = 'failed' and reason <> 'manual' then p_at
                            when st = 'pending' and status = 'failed' then next_try_at else null end,
         updated_at = p_at
   where (p_provider_id is not null and provider_refund_id = p_provider_id)
      or (p_provider_id is null and p_provider_ref is not null and provider_refund_id = p_provider_ref)
      or (reference = p_reference and reason <> 'manual' and (provider_refund_id is null or p_provider_id is null))
  returning * into r;
  if found then return to_jsonb(r); end if;
  select * into att from billing.payment_attempts where reference = p_reference;
  select i.account into acc from billing.invoices i where i.id = att.invoice;
  insert into billing.refunds (attempt, reference, account, amount_minor, currency, reason, status, last_error,
                               provider_refund_id, created_at, updated_at)
  values (att.id, p_reference, acc, p_amount, att.currency, 'manual', st, case when st = 'failed' then p_reason end,
          coalesce(p_provider_id, p_provider_ref), p_at, p_at)
  returning * into r;
  return to_jsonb(r);
end $$;

-- ---------------------------------------------------------------------------
-- record_dispute: charge.dispute.create / .remind / .resolve. A resolved dispute is
-- final: a replay or a later remind changes nothing. The resolution and its effect land
-- in one transaction. Lost: money_back (the current period of a plan still running by
-- the clock ends at once and that card goes off; else the amount is owed on that bill).
-- ---------------------------------------------------------------------------
create function billing.record_dispute(p_reference text, p_event text, p_status text, p_lost boolean,
                                       p_amount int, p_at timestamptz default now(), p_dispute_id text default null)
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  att billing.payment_attempts;
  inv billing.invoices;
  resolve boolean := p_event = 'charge.dispute.resolve';
begin
  select * into att from billing.payment_attempts where reference = p_reference;
  if not found then return jsonb_build_object('action', 'ignored'); end if;
  select * into inv from billing.invoices where id = att.invoice;
  if inv.account is not null then perform billing.lock_account(inv.account); end if;
  select * into att from billing.payment_attempts where id = att.id for update;
  -- final per dispute: the same dispute again changes nothing; a new dispute (another id) on
  -- the same payment is its own
  if att.dispute_resolved_at is not null and (p_dispute_id is null or p_dispute_id is not distinct from att.dispute_id) then
    return jsonb_build_object('action', 'again', 'status', att.dispute_status);
  end if;
  update billing.payment_attempts
     set dispute_status = coalesce(p_status, p_event), dispute_id = coalesce(p_dispute_id, dispute_id),
         dispute_open = not resolve, dispute_resolved_at = case when resolve then p_at end
   where id = att.id
  returning * into att;
  if inv.account is not null then
    perform billing.log_event(inv.account, p_at, 'paystack', 'dispute', null,
                              jsonb_build_object('reference', p_reference, 'dispute', p_dispute_id, 'event', p_event,
                                                 'status', p_status, 'lost', p_lost));
  end if;
  if not (resolve and coalesce(p_lost, false)) then return jsonb_build_object('action', 'recorded'); end if;
  return billing.money_back(att, inv, p_amount, 'dispute_lost', p_at);
end $$;

-- ---------------------------------------------------------------------------
-- Webhook dedupe. event_begin stores the event first: process = false when the same
-- (provider, type, entity, status) was already processed. A stored event that never
-- finished (a crash) is processed again.
-- ---------------------------------------------------------------------------
create function billing.event_begin(p_provider text, p_type text, p_entity text, p_status text, p_payload jsonb,
                                    p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare e billing.payment_events;
begin
  insert into billing.payment_events (provider, event_type, entity_id, status, payload, received_at)
  values (p_provider, p_type, p_entity, coalesce(p_status, ''), p_payload, p_at)
  on conflict (provider, event_type, entity_id, status) do update set tries = payment_events.tries + 1
  returning * into e;
  return jsonb_build_object('id', e.id, 'process', e.processed_at is null);
end $$;

create function billing.event_done(p_id bigint, p_error text default null, p_at timestamptz default now())
returns void language sql security definer set search_path = billing, pg_temp as $$
  update billing.payment_events set processed_at = case when p_error is null then p_at end, last_error = p_error
   where id = p_id
$$;

-- ---------------------------------------------------------------------------
-- delete_account: only none/trialing/ended, nothing owed, no open dispute.
-- Bills, tries, cards and refunds stay with the account reference cleared.
-- ---------------------------------------------------------------------------
create function billing.delete_account(p_account uuid, p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  st billing.status;
  held bigint[];
  unprotected bigint[];
begin
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state not in ('none', 'trialing', 'ended') then
    raise exception 'a plan is running: cancel it and let it run out first' using errcode = '22023';
  end if;
  if exists (select 1 from billing.invoices where account = p_account and amount_owed_minor > 0) then
    raise exception 'money is owed' using errcode = '22023';
  end if;
  if exists (select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
              where i.account = p_account and pa.dispute_open) then
    raise exception 'a dispute is open' using errcode = '22023';
  end if;
  held := array(select plant from billing.seats where account = p_account and closed_at is null order by plant);
  perform billing.lock_plants(held);
  update billing.invoices set status = 'void' where account = p_account and status = 'open';
  delete from billing.accounts where id = p_account;
  update billing.plants set version = version + 1 where id = any (held);
  unprotected := array(select x from unnest(held) x where not (billing.plant_state(x, p_at)->>'protected')::boolean);
  perform billing.log_event(p_account, p_at, p_actor, 'delete_account', jsonb_build_object('state', st.state),
                            jsonb_build_object('unprotected', to_jsonb(unprotected)));
  return jsonb_build_object('deleted', true, 'unprotected', to_jsonb(unprotected));
end $$;

-- ---------------------------------------------------------------------------
-- The daily job. run_one: at most one step for one subscription.
-- ---------------------------------------------------------------------------
create function billing.run_one(p_sub uuid, p_at timestamptz)
returns jsonb language plpgsql set search_path = billing, pg_temp as $$
declare
  s billing.subscriptions;
  m billing.markets;
  inv billing.invoices;
  pm billing.payment_methods;
  att billing.payment_attempts;
  due_from timestamptz;
  last_retry int;
begin
  select * into s from billing.subscriptions where id = p_sub;
  perform billing.lock_account(s.account);
  select * into s from billing.subscriptions where id = p_sub for update;
  if s.status not in ('active', 'past_due') then return null; end if;
  select mk.* into m from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = s.account;
  last_retry := (select max(d) from unnest(m.retry_days) d);

  -- the clock had ended these already: no version bump, so a restart checkout stays good
  if s.cancel_at_period_end and s.period_end <= p_at then
    perform billing.end_sub(s.id, s.period_end, 'cancelled', p_at, 'job', false);
    return jsonb_build_object('step', 'ended', 'reason', 'cancelled');
  end if;
  if s.status = 'past_due' and p_at >= s.past_due_since + make_interval(days => last_retry + 1) then
    perform billing.end_sub(s.id, s.past_due_since + make_interval(days => last_retry + 1), 'unpaid', p_at, 'job', false);
    return jsonb_build_object('step', 'ended', 'reason', 'unpaid');
  end if;
  if s.period_end > p_at then return null; end if;

  inv := billing.ensure_renewal(s.id, p_at);
  if inv.status <> 'open' then return null; end if;
  if s.status = 'active' then
    due_from := s.period_end;                    -- day 0, whenever the job gets to it
    -- day 0 was tried and did not pay (no answer, a bank challenge, an answer lost): the
    -- unpaid window starts from the due date, so day 15 comes whatever happens to that try
    -- The owner's own try on the card page counts at once while it is verified (no answer,
    -- or left open), so the window never waits on a page nobody finished.
    if exists (select 1 from billing.payment_attempts
                where invoice = inv.id and created_at >= s.period_end
                  and ((channel in ('saved_card', 'none')
                        -- a written try with no answer gets a day of verifying before it counts
                        and (status in ('unknown', 'pending', 'failed') or (status = 'created' and claimed_until <= p_at - interval '1 day')))
                    or (channel = 'card_page' and status in ('created', 'unknown', 'pending', 'failed')))) then
      update billing.subscriptions set status = 'past_due', past_due_since = s.period_end, version = version + 1 where id = s.id;
      perform billing.bump(s.account);
      perform billing.log_event(s.account, p_at, 'job', 'renewal_failed', null, jsonb_build_object('invoice', inv.id), 'not paid on its day');
      return jsonb_build_object('step', 'past_due');
    end if;
  else
    due_from := s.past_due_since + make_interval(days =>
                  (select max(d) from unnest(m.retry_days) d where s.past_due_since + make_interval(days => d) <= p_at));
    if due_from is null then return null; end if;
  end if;
  -- this step tried already (only the job's own tries count: a card page the owner left
  -- open does not stop a retry), or a charge may still be taking money (verified first)
  if exists (select 1 from billing.payment_attempts
              where invoice = inv.id and status <> 'void'
                and ((channel in ('saved_card', 'none') and created_at >= due_from) or status in ('created', 'unknown'))) then
    return null;
  end if;
  -- any try on the account that may still take money (a bank challenge, an open card page,
  -- an unanswered charge): nothing is charged again until it is settled or verified
  if exists (select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
              where i.account = s.account and i.status = 'open' and pa.status in ('created', 'pending', 'unknown')) then
    return null;
  end if;

  pm := billing.active_method(s.account);
  if pm.id is null then
    if s.status = 'active' then
      -- nothing to charge on day 0: a failed try, so the window starts
      insert into billing.payment_attempts (invoice, reference, provider, channel, amount_minor, currency, status,
                                            gateway_response, created_at, settled_at)
      values (inv.id, billing.new_reference(), 'paystack', 'none', inv.amount_minor, inv.currency, 'failed',
              'no usable card', p_at, p_at);
      update billing.subscriptions set status = 'past_due', past_due_since = s.period_end, version = version + 1 where id = s.id;
      perform billing.bump(s.account);
      perform billing.log_event(s.account, p_at, 'job', 'renewal_failed', null, jsonb_build_object('invoice', inv.id), 'no usable card');
      return jsonb_build_object('step', 'no_card');
    end if;
    return null;
  end if;
  insert into billing.payment_attempts (invoice, reference, provider, channel, payment_method, amount_minor, currency,
                                        status, claimed_until, created_at)
  values (inv.id, billing.new_reference(), 'paystack', 'saved_card', pm.id, inv.amount_minor, inv.currency,
          'created', p_at + interval '10 minutes', p_at)
  returning * into att;
  return jsonb_build_object('step', 'charge', 'charge', jsonb_build_object(
    'reference', att.reference, 'invoice', inv.id, 'amount_minor', att.amount_minor, 'currency', att.currency,
    'auth_ref', pm.auth_ref, 'auth_email', billing.charge_email(pm.auth_email, s.account)));
end $$;

-- Returns {verify: [references], charges: [...], refunds: [...], steps: {...}} or {busy: true}.
-- Batches are capped (RUN_VERIFY, RUN_CHARGES); what is left goes to the next call.
create function billing.run(p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  r record;
  one jsonb;
  charges jsonb := '[]';
  steps jsonb := '{}';
  verify jsonb;
  refunds jsonb;
begin
  if not pg_try_advisory_xact_lock(hashtext('billing.run')) then return jsonb_build_object('busy', true); end if;
  -- Nothing is failed here without asking Paystack: a try with no answer is verified (below) and
  -- apply_payment fails it only when Paystack still says pending after 24 hours. Every change to
  -- a try goes through apply_payment under its account lock (account, then try).
  -- tries whose lease ran out: Paystack is asked before anything new is charged
  select coalesce(jsonb_agg(reference order by created_at), '[]') into verify from (
    select reference, created_at from billing.payment_attempts
     where status in ('created', 'pending', 'unknown') and claimed_until <= p_at
     order by created_at limit 200) v;
  for r in select id from billing.subscriptions where status in ('active', 'past_due') order by account loop
    exit when jsonb_array_length(charges) >= 300;
    one := billing.run_one(r.id, p_at);
    continue when one is null;
    steps := jsonb_set(steps, array[one->>'step'], to_jsonb(coalesce((steps->>(one->>'step'))::int, 0) + 1));
    if one ? 'charge' then charges := charges || jsonb_build_array(one->'charge'); end if;
  end loop;
  with c as (
    update billing.refunds set status = 'sending', claimed_until = p_at + interval '10 minutes', tries = tries + 1, updated_at = p_at
     where (status in ('due', 'failed') and reason <> 'manual' and (next_try_at is null or next_try_at <= p_at))
        or (status = 'sending' and claimed_until <= p_at)
    returning id, reference, amount_minor)
  select coalesce(jsonb_agg(jsonb_build_object('refund', id, 'reference', reference, 'amount_minor', amount_minor)), '[]')
    into refunds from c;
  return jsonb_build_object('verify', verify, 'charges', charges, 'refunds', refunds, 'steps', steps);
end $$;

-- ---------------------------------------------------------------------------
-- account_state's money facts (replaces 0241's placeholder).
-- ---------------------------------------------------------------------------
create or replace function billing.money_state(p_account uuid, p_at timestamptz, p_state text)
returns jsonb language plpgsql stable set search_path = billing, pg_temp as $$
declare
  pm billing.payment_methods;
  s billing.subscriptions;
  np billing.prices;
  owed int;
  dispute boolean;
  due billing.invoices;
  url text;
  tz text;
begin
  pm := billing.active_method(p_account);
  select mk.default_time_zone into tz from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = p_account;
  owed := (select coalesce(sum(amount_owed_minor), 0) from billing.invoices where account = p_account);
  dispute := exists (select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
                      where i.account = p_account and pa.dispute_open);
  -- a row the clock has ended (the job not run yet) is no running plan
  if p_state in ('active', 'past_due') then s := billing.live_sub(p_account); end if;
  if s.id is not null then
    if s.next_price is not null then select * into np from billing.prices where id = s.next_price; end if;
    select * into due from billing.invoices
     where subscription = s.id and kind = 'renewal' and status = 'open' order by created_at desc limit 1;
    select pay_url into url from billing.payment_attempts
     where invoice = due.id and status = 'pending' and pay_url is not null order by created_at desc limit 1;
  end if;
  return jsonb_build_object(
    'card', case when pm.id is not null then jsonb_build_object('last4', pm.last4, 'exp_month', pm.exp_month,
                                                                 'exp_year', pm.exp_year, 'card_type', pm.card_type) end,
    'card_expires_first', coalesce(pm.id is not null and s.id is not null and not s.cancel_at_period_end
                          and (make_date(pm.exp_year::int, pm.exp_month::int, 1) + interval '1 month')::timestamp
                              at time zone tz <= s.period_end, false),
    'next_plan', case when s.id is not null and not s.cancel_at_period_end then coalesce(np.plan, s.plan) end,
    'next_interval', case when s.id is not null and not s.cancel_at_period_end then coalesce(np.interval, s.interval) end,
    'next_amount_minor', case when s.id is not null and not s.cancel_at_period_end then
                           coalesce(np.amount_minor, s.amount_minor)
                           + coalesce(s.next_extra_places, s.extra_places) * coalesce(np.extra_place_minor, s.extra_place_minor) end,
    'amount_due_minor', due.amount_minor,
    'pay_url', url,
    'owed_minor', owed,
    'dispute_open', dispute,
    'may_delete', p_state in ('none', 'trialing', 'ended') and owed = 0 and not dispute)
    -- past due with no card to charge: no retry or charge date to promise
    || case when p_state = 'past_due' and pm.id is null
            then jsonb_build_object('next_retry_at', null, 'next_charge_at', null) else '{}'::jsonb end;
end $$;

-- ---------------------------------------------------------------------------
-- The one door for the billing function (service role only). The billing schema is
-- not exposed to the API. args.user is the signed-in user's id; the account row is
-- made on first use in the only market (more markets: pass args.market).
-- ---------------------------------------------------------------------------
create function public.billing_v2(p_cmd text, p_args jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
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
    when 'upgrade'          then billing.upgrade(acc, p_args->>'plan', (p_args->>'extras')::int, plants)
    when 'downgrade'        then billing.downgrade(acc, p_args->>'plan', (p_args->>'extras')::int,
                                   array(select jsonb_array_elements_text(coalesce(p_args->'drop', '[]'))::bigint))
    when 'switch_interval'  then billing.switch_interval(acc, p_args->>'interval')
    when 'cancel'           then billing.cancel(acc)
    when 'undo_cancel'      then billing.undo_cancel(acc)
    when 'pay_now'          then billing.pay_now(acc)
    when 'start_card_check' then billing.start_card_check(acc)
    when 'delete_account'   then case when acc is null then jsonb_build_object('deleted', false) else billing.delete_account(acc) end
    when 'begin_attempt'    then billing.begin_attempt((p_args->>'invoice')::uuid, p_args->>'channel')
    when 'attempt_page'     then coalesce(billing.attempt_page(p_args->>'reference', p_args->>'url'), '{}'::jsonb)
    when 'record_refund'    then billing.record_refund((p_args->>'refund')::uuid, p_args->>'error', p_args->>'provider_id')
    when 'record_refund_event' then billing.record_refund_event(p_args->>'reference', p_args->>'status', p_args->>'provider_id',
                                   (p_args->>'amount')::int, p_args->>'reason', now(), p_args->>'provider_ref')
    when 'record_dispute'   then billing.record_dispute(p_args->>'reference', p_args->>'event', p_args->>'status',
                                   (p_args->>'lost')::boolean, (p_args->>'amount')::int, now(), p_args->>'dispute_id')
    when 'event_begin'      then billing.event_begin(p_args->>'provider', p_args->>'type', p_args->>'entity', p_args->>'status', p_args->'payload')
    when 'event_done'       then (select '{}'::jsonb from (select billing.event_done((p_args->>'id')::bigint, p_args->>'error')) x)
    when 'run'              then billing.run()
    when 'attempt_user'     then (select jsonb_build_object('user', a.user_id) from billing.payment_attempts pa
                                   join billing.invoices i on i.id = pa.invoice join billing.accounts a on a.id = i.account
                                  where pa.reference = p_args->>'reference')
  end;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'billing' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
revoke all on function public.billing_v2(text, jsonb) from public, anon, authenticated;
grant execute on function public.billing_v2(text, jsonb) to service_role;
