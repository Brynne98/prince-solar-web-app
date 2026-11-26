-- SOLAR-675: a move to another plan takes the monthly/yearly choice with it, as the old billing
-- did (0155) and as Stripe and Paddle do. The plans pop-up shows every plan at the switch's
-- price, so a tap must buy what it showed.
--
--   bigger plan, monthly to yearly: the new year in full today, less the unused days of the
--     paid month; the year starts at the payment, on a new billing day (apply_upgrade has
--     handled a bill with another interval since 0245)
--   bigger plan, yearly to monthly: the difference for the days left of the year, as now, and
--     monthly from the billing date. Paying the month today would leave a credit larger than
--     the month, and there is no credit balance to keep it in.
--   smaller plan: plan and interval booked together for the billing date, nothing to pay
--
-- upgrade and downgrade take p_interval last (default null: as before, a booked switch carries
-- over), so every existing call keeps its meaning. A given interval wins over a switch booked
-- earlier: the review promised it (review, Astra, Sol, Fable). quote and upgrade share
-- upgrade_due, so the review and the bill are one sum; a bill is reused only at that sum.

-- a bigger plan bought now that turns monthly at the billing date
alter table billing.invoices add column next_interval text check (next_interval in ('month', 'year'));

-- What a move to a bigger plan charges now. The same interval: the difference for the days
-- left, in the market's days. Another interval (monthly to yearly): the new period in full,
-- less the unused days of the paid one. Never below 0.
create function billing.upgrade_due(s billing.subscriptions, m billing.markets, p_new_amt int, p_interval text,
                                    p_at timestamptz)
returns int language sql stable set search_path = billing, pg_temp as $$
  with d as (
    select (s.period_end at time zone m.default_time_zone)::date - (s.period_start at time zone m.default_time_zone)::date as days_all,
           (s.period_end at time zone m.default_time_zone)::date - (p_at at time zone m.default_time_zone)::date as days_to_end,
           s.amount_minor + s.extra_places * s.extra_place_minor as old_amt
  ), l as (
    -- a paid year copied from the old billing starts on its billing date, maybe still ahead:
    -- the days left are that year's
    -- (past the end, as a quote may be asked: none left, review Neon)
    select days_all, greatest(least(days_to_end, days_all), 0) as days_left, old_amt from d
  )
  select greatest(case when p_interval = s.interval
                       then round((p_new_amt - old_amt)::numeric * days_left / greatest(days_all, 1))
                       else p_new_amt - round(old_amt::numeric * days_left / greatest(days_all, 1)) end, 0)::int
    from l
$$;
revoke all on function billing.upgrade_due(billing.subscriptions, billing.markets, int, text, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- upgrade: more places now. p_interval: the interval the pop-up showed (null: the plan's own).
-- ---------------------------------------------------------------------------
drop function billing.upgrade(uuid, text, int, bigint[], timestamptz, text);
create function billing.upgrade(p_account uuid, p_plan text, p_extra_places int, p_plants bigint[],
                                p_at timestamptz default now(), p_actor text default 'owner',
                                p_interval text default null)
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
  due int;
  want bigint[];
  inv billing.invoices;
  iv text;    -- the interval paid for now
  nxt text;   -- the interval from the billing date, when it changes then
begin
  a := billing.lock_account(p_account);
  select * into m from billing.markets where code = a.market;
  st := billing.account_status(p_account, p_at);
  if st.state = 'past_due' then raise exception 'pay the failed payment first' using errcode = '22023'; end if;
  if st.state <> 'active' or st.sub is null then raise exception 'no running plan' using errcode = '22023'; end if;
  if p_interval is not null and p_interval not in ('month', 'year') then
    raise exception 'monthly or yearly' using errcode = '22023';
  end if;
  select * into s from billing.subscriptions where id = st.sub for update;
  -- a cancelled plan buys nothing more: the screen offers Keep first
  if s.cancel_at_period_end then raise exception 'the plan is cancelled' using errcode = '22023'; end if;
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

  -- another plan monthly to yearly: the year now. Otherwise the plan's interval now, and a given
  -- interval from the billing date (it replaces a switch booked earlier)
  iv := case when p_interval = 'year' and s.interval = 'month' and p_plan <> s.plan then 'year' else s.interval end;
  nxt := case when iv = s.interval then p_interval end;
  pr := billing.price_keeping_offer(p_plan, a.market, iv, s.offer, p_at);
  new_amt := pr.amount_minor + extras * pr.extra_place_minor;
  due := billing.upgrade_due(s, m, new_amt, iv, p_at);
  want := billing.final_choice(p_account, p_plants, pl.places + extras + billing.grant_places(p_account, p_at));

  -- the same upgrade again (the card page closed, tried again): the same bill, while its sum is
  -- still today's (a day later the days left are fewer: a new bill at the new sum)
  select * into inv from billing.invoices
   where subscription = s.id and kind = 'upgrade' and status = 'open' and plan = p_plan and extra_places = extras
     and plants = want and expected_version = a.version and period_start = s.period_start
     and interval = iv and next_interval is not distinct from nxt and amount_minor = due
   order by created_at desc limit 1;
  if inv.id is not null then return billing.invoice_out(inv) || jsonb_build_object('applied', false); end if;
  if billing.payment_in_flight(p_account) then
    raise exception 'a payment is already in progress' using errcode = '22023';
  end if;
  perform billing.replace_card_pages(array(select id from billing.invoices
                                            where subscription = s.id and kind = 'upgrade' and status = 'open'), p_at);
  update billing.invoices set status = 'void' where subscription = s.id and kind = 'upgrade' and status = 'open';
  -- the bill names the period it is bought in; apply_upgrade moves it to the new year when the
  -- interval changes now
  insert into billing.invoices (account, subscription, kind, status, price, plan, interval, next_interval, offer, extra_places,
                                plan_amount_minor, extra_place_minor, amount_minor, tax_minor, currency, period_start,
                                period_end, period_key, expected_version, plants, created_at)
  values (p_account, s.id, 'upgrade', case when due < m.min_charge_minor then 'waived' else 'open' end, pr.id, p_plan,
          iv, nxt, s.offer, extras, pr.amount_minor, pr.extra_place_minor, due, pr.tax_minor, s.currency,
          s.period_start, s.period_end,
          extract(epoch from s.period_start)::bigint || ':' || p_plan || '+' || extras
            || case when iv <> s.interval then '@' || iv when nxt is not null then '>' || nxt else '' end,
          a.version, want, p_at)
  returning * into inv;
  perform billing.log_event(p_account, p_at, p_actor, 'upgrade',
                            jsonb_build_object('plan', s.plan, 'extras', s.extra_places, 'interval', s.interval),
                            jsonb_build_object('invoice', inv.id, 'plan', p_plan, 'extras', extras, 'due', due,
                                               'interval', iv, 'next_interval', nxt,
                                               'waived', inv.status = 'waived', 'plants', to_jsonb(want)));
  if inv.status = 'waived' then
    declare held boolean := billing.reading_held(p_account, p_at);              -- 0256
    begin
      perform billing.apply_upgrade(inv, p_at);
      if held and not billing.reading_held(p_account, p_at) then perform billing.readings_resume(p_account, p_at); end if;
    end;
    perform billing.bump(p_account);
    return billing.invoice_out(inv) || jsonb_build_object('applied', true);
  end if;
  return billing.invoice_out(inv) || jsonb_build_object('applied', false);
end $$;
revoke all on function billing.upgrade(uuid, text, int, bigint[], timestamptz, text, text) from public, anon, authenticated;

-- apply_upgrade: a bill with an interval from the billing date (next_interval) books that on the
-- new plan, or clears a switch booked earlier when it is the running interval. The interval
-- change now (a bill with another interval) was there since 0245.
do $$
declare
  d text := pg_get_functiondef('billing.apply_upgrade(billing.invoices, timestamptz)'::regprocedure);
  old text := $o$  -- an old monthly-to-yearly charge (copy_from_old): the same plan is paid a year past its
  -- billing date; a bigger plan runs yearly from the payment, on a new billing day
$o$;
begin
  if position(old in d) = 0 then raise exception 'apply_upgrade changed since 0245: edit it by hand'; end if;
  d := replace(d, old, $n$  -- the interval the move was made at, from the billing date (0278): it wins over a switch
  -- booked earlier
  if p_inv.next_interval is not null and p_inv.interval = s.interval then
    update billing.subscriptions
       set next_price = case when p_inv.next_interval <> s.interval
                             then (billing.price_keeping_offer(p_inv.plan, a.market, p_inv.next_interval, s.offer, p_at)).id end
     where id = s.id;
  end if;
  -- another interval now: an old monthly-to-yearly charge (copy_from_old) pays the same plan a
  -- year past its billing date; a bigger plan monthly to yearly (0278, and copy_from_old) runs
  -- yearly from the payment, on a new billing day
$n$);
  execute d;
end $$;

-- ---------------------------------------------------------------------------
-- downgrade: fewer places from the next billing date. p_drop: the plants that go.
-- The same plan and places as now: the booking is undone. p_extra_places null: the extra
-- places it has now on the same plan (so an undo keeps them), none on another plan.
-- p_interval: the interval from that date (null: a booked switch, else the plan's own).
-- ---------------------------------------------------------------------------
drop function billing.downgrade(uuid, text, int, bigint[], timestamptz, text);
create function billing.downgrade(p_account uuid, p_plan text, p_extra_places int, p_drop bigint[],
                                  p_at timestamptz default now(), p_actor text default 'owner',
                                  p_interval text default null)
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  a billing.accounts;
  st billing.status;
  s billing.subscriptions;
  pl billing.plans;
  pr billing.prices;
  np billing.prices;
  extras int;
  cur_places int;
  new_places int;
  drop_ids bigint[];
  bad bigint;
  iv text;
begin
  a := billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state <> 'active' or st.sub is null then raise exception 'no running plan' using errcode = '22023'; end if;
  if p_interval is not null and p_interval not in ('month', 'year') then
    raise exception 'monthly or yearly' using errcode = '22023';
  end if;
  select * into s from billing.subscriptions where id = st.sub for update;
  if s.cancel_at_period_end then raise exception 'the plan is cancelled' using errcode = '22023'; end if;
  if s.period_end <= p_at then raise exception 'the renewal is due: pay it first' using errcode = '22023'; end if;
  select * into pl from billing.plans where code = p_plan;
  if not found then raise exception 'no such plan' using errcode = '22023'; end if;
  extras := coalesce(p_extra_places, case when p_plan = s.plan then s.extra_places else 0 end);
  if extras < 0 or (extras > 0 and not pl.allows_extra) then
    raise exception 'extra places are not sold on %', pl.name using errcode = '22023';
  end if;
  cur_places := (select places from billing.plans where code = s.plan) + s.extra_places;
  new_places := pl.places + extras;
  if s.next_price is not null then select * into np from billing.prices where id = s.next_price; end if;
  iv := coalesce(p_interval, np.interval, s.interval);

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
                            jsonb_build_object('plan', p_plan, 'extras', extras, 'drop', to_jsonb(drop_ids), 'interval', iv));
  return billing.account_state(p_account, p_at);
end $$;
revoke all on function billing.downgrade(uuid, text, int, bigint[], timestamptz, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- What a plan change would charge: a first plan or restart (purchase), an upgrade now (the
-- same sum as billing.upgrade), or a booked downgrade or interval. An upgrade's `interval` and
-- next amount are from the billing date on; `starts_now`: the new period begins at the payment.
-- ---------------------------------------------------------------------------
create or replace function billing.quote(p_account uuid, p_plan text, p_interval text, p_at timestamptz default now())
returns jsonb language plpgsql stable set search_path = billing, pg_temp as $$
declare
  a billing.accounts;
  m billing.markets;
  st billing.status;
  s billing.subscriptions;
  pl billing.plans;
  pr billing.prices;
  npr billing.prices;
  cur_places int;
  due int;
  iv text;
  nxt text;
begin
  select * into a from billing.accounts where id = p_account;
  select * into m from billing.markets where code = a.market;
  st := billing.account_status(p_account, p_at);
  select * into pl from billing.plans where code = p_plan;
  if not found then raise exception 'no such plan' using errcode = '22023'; end if;
  if st.sub is null then
    -- a first plan is monthly unless asked (api_plan_quote passes null through since 0278)
    p_interval := coalesce(p_interval, 'month');
    pr := billing.price_shown(p_account, p_plan, p_interval, p_at);
    return jsonb_build_object('kind', 'purchase', 'plan', p_plan, 'plan_name', pl.name, 'places', pl.places,
      'interval', p_interval, 'due_minor', pr.amount_minor, 'next_amount_minor', pr.amount_minor,
      'next_at', billing.add_period(p_at, p_interval, extract(day from p_at at time zone m.default_time_zone)::int, m.default_time_zone),
      'currency', m.currency, 'offer', pr.offer);
  end if;
  s := billing.live_sub(p_account);
  cur_places := (select places from billing.plans where code = s.plan) + s.extra_places;
  if pl.places > cur_places then
    iv := case when p_interval = 'year' and s.interval = 'month' and p_plan <> s.plan then 'year' else s.interval end;
    nxt := case when iv = s.interval then p_interval end;
    pr := billing.price_keeping_offer(p_plan, a.market, iv, s.offer, p_at);
    if nxt is not null then npr := billing.price_keeping_offer(p_plan, a.market, nxt, s.offer, p_at); end if;
    due := billing.upgrade_due(s, m, pr.amount_minor, iv, p_at);
    return jsonb_build_object('kind', 'upgrade', 'plan', p_plan, 'plan_name', pl.name, 'places', pl.places,
      'interval', coalesce(nxt, iv), 'starts_now', iv <> s.interval,
      'due_minor', case when due < m.min_charge_minor then 0 else due end,
      'next_amount_minor', coalesce(npr.amount_minor, pr.amount_minor),
      'next_at', case when iv <> s.interval
                      then billing.add_period(p_at, iv, extract(day from p_at at time zone m.default_time_zone)::int, m.default_time_zone)
                      else s.period_end end,
      'currency', s.currency, 'offer', pr.offer);
  end if;
  pr := billing.price_keeping_offer(p_plan, a.market, coalesce(p_interval, s.interval), s.offer, p_at);
  return jsonb_build_object('kind', case when pl.places < cur_places then 'downgrade' else 'interval' end,
    'plan', p_plan, 'plan_name', pl.name, 'places', pl.places, 'interval', pr.interval, 'due_minor', 0,
    'next_amount_minor', pr.amount_minor, 'next_at', s.period_end, 'currency', s.currency, 'offer', pr.offer,
    'drop', greatest(st.chosen - pl.places - billing.grant_places(p_account, p_at), 0));
end $$;

-- a running plan's quote without an interval is its own interval, not monthly (review, Astra)
create or replace function public.api_plan_quote(p_plan text, p_interval text default null)
returns jsonb language plpgsql stable security definer set search_path = billing, pg_temp as $$
declare acc uuid := billing.account_of(auth.uid(), false);
begin
  if acc is null then raise exception 'sign in first' using errcode = '42501'; end if;
  return billing.quote(acc, p_plan, p_interval);
end $$;

-- record_dispute: the bill is read again under the account's lock, so a payment applied while
-- the dispute waited (an upgrade moves its bill to the new year) is seen (review, Sol)
do $$
declare
  d text := pg_get_functiondef('billing.record_dispute(text, text, text, boolean, int, timestamptz, text)'::regprocedure);
  old text := $o$  if inv.account is not null then perform billing.lock_account(inv.account); end if;
$o$;
begin
  if position(old in d) = 0 then raise exception 'record_dispute changed since 0245: edit it by hand'; end if;
  d := replace(d, old, old || $n$  select * into inv from billing.invoices where id = att.invoice;
$n$);
  execute d;
end $$;

-- apply_payment: a move monthly to yearly is priced on its day (the credit is the days left
-- then): one paid on a later day is stale and refunded, and the move is asked again (review, Neon)
do $$
declare
  d text := pg_get_functiondef('billing.apply_payment(text, jsonb, timestamptz)'::regprocedure);
  old text := $o$      when inv.kind = 'upgrade' and (s.period_start <> inv.period_start or inv.period_end <= paid$o$;
begin
  if position(old in d) = 0 then raise exception 'apply_payment changed since 0256: edit it by hand'; end if;
  d := replace(d, old, $n$      when inv.kind = 'upgrade' and inv.period_key like '%@%'
           and (paid at time zone (select mk.default_time_zone from billing.markets mk where mk.code = a.market))::date
               <> (inv.created_at at time zone (select mk.default_time_zone from billing.markets mk where mk.code = a.market))::date
        then 'stale'
$n$ || old);
  execute d;
end $$;

-- billing_v2: the pay and change calls pass the interval the pop-up showed
do $$
declare
  d text := pg_get_functiondef('public.billing_v2(text, jsonb)'::regprocedure);
  up text := $o$billing.upgrade(acc, p_args->>'plan', (p_args->>'extras')::int, plants)$o$;
  dn text := $o$billing.downgrade(acc, p_args->>'plan', (p_args->>'extras')::int,
                                   array(select jsonb_array_elements_text(coalesce(p_args->'drop', '[]'))::bigint))$o$;
begin
  if position(up in d) = 0 or position(dn in d) = 0 then raise exception 'billing_v2 changed since 0254: edit it by hand'; end if;
  d := replace(d, up, $n$billing.upgrade(acc, p_args->>'plan', (p_args->>'extras')::int, plants, p_interval => p_args->>'interval')$n$);
  d := replace(d, dn, $n$billing.downgrade(acc, p_args->>'plan', (p_args->>'extras')::int,
                                   array(select jsonb_array_elements_text(coalesce(p_args->'drop', '[]'))::bigint),
                                   p_interval => p_args->>'interval')$n$);
  execute d;
end $$;

-- outbox_take: the receipt of a move monthly to yearly names the year it bought (starts_now);
-- one that turns monthly at the billing date names the monthly amount as the next payment
do $$
declare
  d text := pg_get_functiondef('billing.outbox_take(int, timestamptz)'::regprocedure);
  old text := $o$'next_amount_minor', inv.plan_amount_minor + inv.extra_places * inv.extra_place_minor,$o$;
begin
  if position(old in d) = 0 then raise exception 'outbox_take changed since 0276: edit it by hand'; end if;
  d := replace(d, old, $n$'next_amount_minor', case when inv.next_interval is not null
                  then (select np.amount_minor + inv.extra_places * np.extra_place_minor
                          from billing.price_keeping_offer(inv.plan, (select market from billing.accounts where id = inv.account),
                                                           inv.next_interval, inv.offer, inv.paid_at) np)
                  else inv.plan_amount_minor + inv.extra_places * inv.extra_place_minor end,
                'starts_now', inv.kind = 'upgrade' and inv.period_key like '%@%',$n$);
  execute d;
end $$;
