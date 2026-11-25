-- ============================================================================
-- 0248 — an unpaid renewal says what happened and what to do (SOLAR-644).
--
-- Spec: reports/refused-card-spec-2026-11-24.md (v13).
--
--   Cutoff     an unpaid plan now ends at the end of the local day its last retry day
--              lands on (billing.past_due_cutoff): the last millisecond of that day in
--              the account's time zone, so "Pay by 8 Dec 2026" holds all of 8 Dec. Used by
--              account_status, the daily job (run_one) and a restart (apply_purchase).
--   State      account_state carries past_due_reason (refused, no_card, retrying,
--              last_try_failed, checking), next_try_on, retry_window_ends_at, due_bill,
--              renewal_in_flight, held_reference and refused_card (billing.renewal_state).
--   In flight  a renewal paid before the cutoff may be answered after it: a saved-card
--              try with no final answer, or a card page Paystack said is still processing
--              (verified_processing) or did not answer (verify_unanswered_at), for 24 hours
--              from the cutoff (billing.renewal_hold). While it holds the plan runs on past
--              its cutoff (readings go on, the screens say "checking"), no new plan, and the
--              daily job does not end it. At cutoff + 24 hours such a card page is failed, and
--              the plan ends with ended_at = the cutoff.
--   Payable    begin_attempt takes the owner's account and pays a renewal only while its
--              plan runs (active on its due day, or past due).
--   Emails     a failed card page sends nothing; no card on the due date sends the new
--              payment_due; card_update names the refused try; plan_ended is keyed per
--              ending, held while a renewal payment may still land, and carries why it
--              ended (outbox_take 'ended').
-- ============================================================================

alter table billing.payment_attempts add column verified_processing boolean not null default false;
alter table billing.payment_attempts add column verify_unanswered_at timestamptz;
alter table billing.outbox add column ended_at timestamptz;      -- plan_ended: the ending it is about
insert into billing.outbox_kinds (key, reminder) values ('payment_due', false);

-- The end of an unpaid window: the last millisecond of the local day that lands
-- max(retry_days) + 1 days after past_due_since. Null when past_due_since is null.
create function billing.past_due_cutoff(p_since timestamptz, p_retry_days int[], p_tz text)
returns timestamptz language sql immutable set search_path = billing, pg_temp as $$
  select (((p_since at time zone p_tz)::date + (select max(d) from unnest(p_retry_days) d) + 2)::timestamp
          at time zone p_tz) - interval '1 millisecond'
$$;

-- A plan's cutoff: when it ended, else when its unpaid window ends (null: not past due).
create function billing.sub_cutoff(p_sub uuid)
returns timestamptz language sql stable set search_path = billing, pg_temp as $$
  select coalesce(s.ended_at, billing.past_due_cutoff(s.past_due_since, m.retry_days, coalesce(a.time_zone, m.default_time_zone)))
    from billing.subscriptions s join billing.accounts a on a.id = s.account join billing.markets m on m.code = a.market
   where s.id = p_sub
$$;

-- The daily job's next run at or after p_from: cron billing-run, '*/5 4-5 * * *' UTC
-- (0268). Change both together.
create function billing.next_run_at(p_from timestamptz)
returns timestamptz language sql immutable set search_path = billing, pg_temp as $$
  select case when (p_from at time zone 'UTC')::time < time '04:00'
                then ((p_from at time zone 'UTC')::date + time '04:00') at time zone 'UTC'
              when (p_from at time zone 'UTC')::time <= time '05:55' then p_from
              else ((p_from at time zone 'UTC')::date + 1 + time '04:00') at time zone 'UTC' end
$$;

-- A renewal payment that may still land, on the latest plan's latest renewal bill (open or
-- void): (a) a saved-card try with no final answer, or (b) a card page made before the
-- cutoff that Paystack said is still processing or did not answer. Either until cutoff + 24
-- hours, so a try Paystack never answers cannot hold a restart for ever.
-- held_reference: the oldest (b) page, once the cutoff has passed (the app re-checks it).
create function billing.renewal_hold(p_account uuid, p_at timestamptz,
                                     out in_flight boolean, out held_reference text, out bill uuid, out cutoff timestamptz)
language plpgsql stable set search_path = billing, pg_temp as $$
declare s billing.subscriptions; inv billing.invoices;
begin
  in_flight := false;
  select * into s from billing.subscriptions where account = p_account and started_at <= p_at
   order by started_at desc limit 1;
  if s.id is null then return; end if;
  select * into inv from billing.invoices where subscription = s.id and kind = 'renewal' order by created_at desc limit 1;
  if inv.id is null or inv.status not in ('open', 'void') then return; end if;
  bill := inv.id;
  cutoff := billing.sub_cutoff(s.id);
  select pa.reference into held_reference from billing.payment_attempts pa
   where pa.invoice = inv.id and pa.channel = 'card_page' and pa.status in ('created', 'pending', 'unknown')
     and (pa.verified_processing or pa.verify_unanswered_at is not null)
     and (cutoff is null or (pa.created_at < cutoff and p_at < cutoff + interval '24 hours'))
   order by pa.created_at limit 1;
  in_flight := held_reference is not null
               or (exists (select 1 from billing.payment_attempts pa where pa.invoice = inv.id and pa.channel = 'saved_card'
                              and pa.status in ('created', 'pending', 'unknown'))
                   and (cutoff is null or p_at < cutoff + interval '24 hours'));
  if cutoff is null or p_at < cutoff then held_reference := null; end if;
end $$;

-- The unpaid renewal's facts for account_state: why it is unpaid, when the card is tried next
-- (the day of the next daily run before the cutoff), when an open screen should read again, the
-- bill owed, and whether a payment on it may still land.
create function billing.renewal_state(p_account uuid, p_at timestamptz, st billing.status)
returns jsonb language plpgsql stable set search_path = billing, pg_temp as $$
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
end $$;

-- plan_ended waits (outbox_take skips it) while a renewal payment on that plan may still land:
-- renewal_hold, or any card page on the renewal bill made before the cutoff and not answered
-- yet (the daily job verifies it in the run that ends the plan), at most 24 hours from the cutoff.
create function billing.plan_ended_held(p_account uuid, p_sub text, p_at timestamptz)
returns boolean language plpgsql stable set search_path = billing, pg_temp as $$
declare h record;
begin
  if (select s.id::text from billing.subscriptions s where s.account = p_account order by started_at desc limit 1)
     is distinct from p_sub then return false; end if;
  select * into h from billing.renewal_hold(p_account, p_at);
  if h.in_flight then return true; end if;
  if h.bill is null or h.cutoff is null or p_at >= h.cutoff + interval '24 hours' then return false; end if;
  return exists (select 1 from billing.payment_attempts pa where pa.invoice = h.bill and pa.channel = 'card_page'
                    and pa.status in ('created', 'pending', 'unknown') and pa.created_at < h.cutoff);
end $$;

-- What a plan_ended email says: the ending's date and reason (its own plan_ended event), and
-- whether a card page made before it never got a final answer (then it does not say "It wasn't paid").
create function billing.plan_ended_facts(o billing.outbox)
returns jsonb language sql stable set search_path = billing, pg_temp as $$
  select jsonb_build_object(
    'ended_at', coalesce(o.ended_at, s.ended_at),
    'reason', (select e.reason from billing.account_events e
                where e.account = o.account and e.kind = 'plan_ended' and e.after->>'sub' = o.ref
                  and (o.ended_at is null or (e.after->>'ended_at')::timestamptz = o.ended_at)
                order by e.at desc, e.id desc limit 1),
    'paid_unknown', exists (select 1 from billing.payment_attempts pa
                             where pa.invoice = (select i.id from billing.invoices i where i.subscription = s.id
                                                    and i.kind = 'renewal' order by i.created_at desc limit 1)
                               and pa.channel = 'card_page' and pa.created_at < coalesce(o.ended_at, s.ended_at)
                               and (pa.status in ('created', 'pending', 'unknown')
                                    or (pa.status = 'failed' and pa.gateway_response like 'timeout: %'))))
    from billing.subscriptions s where s.id::text = o.ref
$$;

-- Paystack gave no usable answer about a renewal card page (timeout, gateway error): recorded
-- under the account lock unless the try has settled, so the screen and a refused restart agree.
-- At cutoff + 24 hours the page is failed instead (as apply_payment does).
create function billing.verify_unanswered(p_reference text, p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare att billing.payment_attempts; inv billing.invoices;
begin
  -- on hold for the way back (billing.pause_payments): no try changes, as in apply_payment
  lock table billing.payments_pause in share mode;
  if exists (select 1 from billing.payments_pause) then
    raise exception 'payments are on hold for an update' using errcode = '55000';
  end if;
  select * into att from billing.payment_attempts where reference = p_reference;
  if not found then return jsonb_build_object('action', 'ignored'); end if;
  select * into inv from billing.invoices where id = att.invoice;
  if inv.account is not null then perform billing.lock_account(inv.account); end if;
  select * into att from billing.payment_attempts where id = att.id for update;
  if att.status not in ('created', 'pending', 'unknown') or att.channel <> 'card_page' or inv.kind <> 'renewal' then
    return jsonb_build_object('action', 'unanswered');
  end if;
  if p_at >= billing.sub_cutoff(inv.subscription) + interval '24 hours' then
    update billing.payment_attempts
       set status = 'failed', gateway_response = 'timeout: no final answer 24 hours after the plan ended',
           settled_at = p_at, claimed_until = null, verified_processing = false, verify_unanswered_at = null
     where id = att.id;
    return jsonb_build_object('action', 'failed', 'kind', inv.kind, 'declined', false, 'hard', false);
  end if;
  update billing.payment_attempts set verify_unanswered_at = coalesce(verify_unanswered_at, p_at) where id = att.id;
  return jsonb_build_object('action', 'unanswered');
end $$;

-- Before a restart: the card pages on the latest renewal bill that Paystack has not answered
-- finally, lease or not. The billing function asks Paystack about each before start_checkout.
create function billing.renewal_pages(p_account uuid, p_at timestamptz default now())
returns jsonb language sql stable set search_path = billing, pg_temp as $$
  select coalesce(jsonb_agg(pa.reference order by pa.created_at), '[]'::jsonb)
    from billing.payment_attempts pa
   where pa.invoice = (select h.bill from billing.renewal_hold(p_account, p_at) h)
     and pa.channel = 'card_page' and pa.status in ('created', 'pending', 'unknown')
$$;

-- begin_attempt gains the caller's account (below): the old one goes, so calls stay unambiguous.
drop function billing.begin_attempt(uuid, text, timestamptz);

create or replace function billing.account_status(p_account uuid, p_at timestamptz)
returns billing.status language plpgsql stable set search_path = billing, pg_temp as $$
declare
  a  billing.accounts;
  m  billing.markets;
  s  billing.subscriptions;
  r  billing.status;
  has_sub boolean;
  sub_end timestamptz;
  pds timestamptz;
  eff text;
  grant_places int;
  grant_last timestamptz;
  grant_any boolean;
begin
  select * into a from billing.accounts where id = p_account;
  if not found then return null; end if;
  select * into m from billing.markets where code = a.market;
  r.retention_days := m.retention_days;
  r.retry_days := m.retry_days;
  r.currency := m.currency;
  r.trial_ends_at := a.trial_ends_at;

  -- the latest plan begun by `at`
  select * into s from billing.subscriptions
   where account = p_account and started_at <= p_at order by started_at desc limit 1;
  has_sub := found;
  if has_sub then
    pds := case when s.status = 'past_due' then s.past_due_since end;
    if s.status = 'ended' then
      sub_end := s.ended_at;
    elsif s.cancel_at_period_end and s.period_end <= p_at then
      sub_end := s.period_end;
    else
      if pds is not null then
        r.plan_ends_at := billing.past_due_cutoff(pds, m.retry_days, coalesce(a.time_zone, m.default_time_zone));
        -- a payment made before the cutoff and not answered yet keeps it running, at most a day
        if r.plan_ends_at <= p_at and not (select h.in_flight from billing.renewal_hold(p_account, p_at) h) then
          sub_end := r.plan_ends_at;
        end if;
      end if;
    end if;
    eff := case when sub_end is not null and sub_end <= p_at then 'ended'
                when pds is not null and pds <= p_at then 'past_due'
                else 'active' end;
    if eff <> 'ended' then
      r.sub := s.id; r.plan := s.plan; r.interval := s.interval; r.amount_minor := s.amount_minor;
      r.currency := s.currency; r.period_end := s.period_end;
      r.cancel_at := case when s.cancel_at_period_end then s.period_end end;
      r.past_due_since := case when eff = 'past_due' then pds end;
      r.plan_ends_at := case when eff = 'past_due' then least(r.plan_ends_at, r.cancel_at) else r.cancel_at end;
    end if;
  end if;

  select coalesce(sum(g.places) filter (where g.starts_at <= p_at and (g.ends_at is null or g.ends_at > p_at)), 0),
         max(g.ends_at) filter (where g.ends_at <= p_at),
         coalesce(bool_or(g.starts_at <= p_at), false)
    into grant_places, grant_last, grant_any
    from billing.grants g where g.account = p_account;

  if eff in ('active', 'past_due') then
    r.state := eff;
    r.places := (select p.places from billing.plans p where p.code = s.plan) + s.extra_places + grant_places;
  elsif grant_places > 0 then
    r.state := 'active';
    r.places := grant_places;
  elsif a.trial_started_at <= p_at and p_at < a.trial_ends_at then
    r.state := 'trialing';
    r.places := m.trial_places;
  elsif a.trial_started_at <= p_at or has_sub or grant_any then
    r.state := 'ended';
  elsif exists (select 1 from billing.linked_plants(p_account))
        and not exists (select 1 from billing.linked_plants(p_account) t (x) join billing.plants p on p.id = t.x
                         where p.trial_used_at is null or p.trial_used_by = p_account) then
    r.state := 'ended';                          -- nothing left to try: pay screen
  else
    r.state := 'none';
  end if;
  r.places := coalesce(r.places, 0);

  r.chosen := (select count(*) from billing.seats se
                where se.account = p_account and se.chosen_at <= p_at and (se.closed_at is null or se.closed_at > p_at));
  r.linked := (select count(*) from billing.linked_plants(p_account));
  r.must_choose := r.state in ('trialing', 'active', 'past_due') and r.chosen > r.places;

  if r.state = 'ended' then
    r.access_ended_at := greatest(case when a.trial_ends_at <= p_at then a.trial_ends_at end,
                                  case when sub_end <= p_at then sub_end end,
                                  grant_last);
  end if;
  return r;
end $$;

create or replace function billing.account_state(p_account uuid, p_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = billing, pg_temp as $$
declare
  st billing.status;
  live boolean;
  next_retry timestamptz;
  fit text;
  plants jsonb;
  login_count int;
begin
  st := billing.account_status(p_account, p_at);
  if st is null then return null; end if;
  live := st.state in ('trialing', 'active', 'past_due');

  if st.state = 'past_due' then
    select min(st.past_due_since + make_interval(days => d)) into next_retry
      from unnest(st.retry_days) d where st.past_due_since + make_interval(days => d) > p_at;
  end if;

  -- the smallest plan that fits every linked plant; null when none does
  select p.code into fit from billing.plans p where p.places >= st.linked order by p.places limit 1;

  login_count := (select count(*) from billing.logins l where l.account = p_account);

  select coalesce(jsonb_agg(jsonb_build_object(
           'plant', x.plant,
           'name', coalesce((select lp.plant_name from billing.login_plants lp join billing.logins l on l.id = lp.login
                              where l.account = p_account and lp.plant = x.plant and lp.plant_name is not null limit 1),
                            (select c.plant_name from billing.plant_claims c where c.account = p_account and c.plant = x.plant),
                            -- a share removed (no claim left): the name it had
                            (select pu.plant_name from public.plant_users pu where pu.user_id = (select ac.user_id from billing.accounts ac where ac.id = p_account)
                                and pu.plant_id = x.plant and pu.plant_name is not null limit 1)),
           'chosen', x.chosen,
           'locked', not x.chosen,
           'read_now', x.chosen and live and not st.must_choose and billing.has_route(p_account, x.plant, true),
           'needs_reconnect', billing.has_route(p_account, x.plant, false) and not billing.has_route(p_account, x.plant, true),
           'trial_used_elsewhere', pl.trial_used_at is not null and pl.trial_used_by is distinct from p_account,
           'delete_at', ps->'delete_at',
           'purged', ps->'purged') order by x.plant), '[]'::jsonb)
    into plants
    from (select y.plant, exists (select 1 from billing.seats se where se.account = p_account and se.plant = y.plant
                                     and se.chosen_at <= p_at and (se.closed_at is null or se.closed_at > p_at)) as chosen
            from (select t.x from billing.linked_plants(p_account) t (x)
                  union
                  select se.plant from billing.seats se where se.account = p_account
                     and se.chosen_at <= p_at and (se.closed_at is null or se.closed_at > p_at)) y (plant)) x
    join billing.plants pl on pl.id = x.plant
    cross join lateral billing.plant_state(x.plant, p_at) ps;

  return jsonb_build_object(
    'state', st.state,
    'plan', st.plan,
    'interval', st.interval,
    'amount_minor', st.amount_minor,
    'currency', st.currency,
    'places', st.places,
    'chosen', st.chosen,
    'linked', st.linked,
    'open', greatest(st.places - st.chosen, 0),
    'must_choose', st.must_choose,
    'trial_ends_at', st.trial_ends_at,
    'period_end', st.period_end,
    'cancel_at', st.cancel_at,
    'next_charge_at', case when st.state = 'active' and st.sub is not null and st.cancel_at is null then st.period_end
                           when st.state = 'past_due' then next_retry end,
    'next_retry_at', next_retry,
    'past_due_since', st.past_due_since,
    'plan_ends_at', st.plan_ends_at,
    'access_ended_at', st.access_ended_at,
    'may_add_login', case st.state when 'ended' then false
                                   when 'none' then login_count = 0
                                   when 'trialing' then login_count = 0
                                   else true end,
    'may_choose', st.state in ('trialing', 'active') or (st.state = 'none' and st.linked > 0),
    'may_switch', st.state in ('trialing', 'active'),
    'fit_all_plan', fit,
    'plants', plants) || billing.money_state(p_account, p_at, st.state) || billing.renewal_state(p_account, p_at, st);
end $$;

create or replace function billing.start_checkout(p_account uuid, p_plan text, p_interval text, p_extra_places int,
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
  -- a renewal paid before its plan ended may still be on its way: answered first (0248)
  if (select h.in_flight from billing.renewal_hold(p_account, p_at) h) then
    raise exception 'a payment is already in progress' using errcode = '22023';
  end if;
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

create or replace function billing.apply_purchase(p_inv billing.invoices, p_at timestamptz)
returns void language plpgsql set search_path = billing, pg_temp as $$
declare
  m billing.markets;
  sid uuid;
  day int;
  pe timestamptz;
  had bigint[];
  restart boolean;
  old billing.subscriptions;
  tz text;
begin
  select mk.* into m from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = p_inv.account;
  tz := coalesce((select a.time_zone from billing.accounts a where a.id = p_inv.account), m.default_time_zone);
  restart := (billing.account_status(p_inv.account, p_at)).state = 'ended';
  old := billing.live_sub(p_inv.account);
  if old.id is not null then
    if old.cancel_at_period_end and old.period_end <= p_at then
      perform billing.end_sub(old.id, old.period_end, 'cancelled', p_at, 'paystack', false);
    else
      perform billing.end_sub(old.id, coalesce(billing.past_due_cutoff(old.past_due_since, m.retry_days, tz), p_at),
                              'unpaid', p_at, 'paystack', false);
    end if;
  end if;
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
  if restart then
    perform billing.request_history(p_inv.account, array(select x from unnest(p_inv.plants) x where x = any (had)), p_at);
  end if;
end $$;

create function billing.begin_attempt(p_invoice uuid, p_channel text, p_at timestamptz default now(),
                                      p_account uuid default null)
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  inv billing.invoices;
  pm billing.payment_methods;
  att billing.payment_attempts;
  stale jsonb;
  st billing.status;
begin
  -- share lock first: pause_payments' insert then waits for every try already under way, so
  -- none is written after switch_off has looked (go-live review, Astra)
  lock table billing.payments_pause in share mode;
  if exists (select 1 from billing.payments_pause) then
    raise exception 'payments are on hold for an update' using errcode = '55000';
  end if;
  select * into inv from billing.invoices where id = p_invoice;
  if not found or inv.account is null or inv.account is distinct from coalesce(p_account, inv.account) then
    raise exception 'no such bill' using errcode = 'P0002';
  end if;
  perform billing.lock_account(inv.account);
  select * into inv from billing.invoices where id = p_invoice for update;
  if inv.status = 'paid' then raise exception 'this payment has already been made' using errcode = '22023'; end if;
  if inv.status <> 'open' then raise exception 'this payment is no longer due' using errcode = '22023'; end if;
  -- a renewal is payable while its plan runs: past due, or active on its due day before the
  -- job (pay_now, a new card). Not between the cutoff and the job, when the bill is still open.
  if inv.kind = 'renewal' then
    st := billing.account_status(inv.account, p_at);
    if st.state not in ('active', 'past_due') or st.sub is distinct from inv.subscription then
      raise exception 'this payment is no longer due' using errcode = '22023';
    end if;
    -- past the cutoff and still running: a payment on it is being checked
    if st.plan_ends_at <= p_at then raise exception 'a payment is already in progress' using errcode = '22023'; end if;
  end if;
  -- a new plan waits for a renewal paid before its plan ended (before the cached page below)
  if inv.kind = 'purchase' and (select h.in_flight from billing.renewal_hold(inv.account, p_at) h) then
    raise exception 'a payment is already in progress' using errcode = '22023';
  end if;
  if p_channel not in ('saved_card', 'card_page') then raise exception 'bad channel' using errcode = '22023'; end if;
  -- the bill's plants and the account's seats, so the delete job cannot purge them under a
  -- payment that is starting (it skips a plant held by a try: payment_hold)
  perform billing.lock_plants(coalesce(inv.plants, '{}')
                              || array(select plant from billing.seats where account = inv.account and closed_at is null));

  if p_channel = 'card_page' then
    select * into att from billing.payment_attempts
     where invoice = p_invoice and channel = 'card_page' and status = 'pending' and pay_url is not null
       and claimed_until > p_at and replaced_at is null
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
    -- an open card page can still take money, on any bill (a replaced bill's page too):
    -- Paystack is asked first, and while it may still settle nothing is charged (the caller
    -- gets {verify} again and says a payment is under way)
    select jsonb_agg(pa.reference order by pa.created_at) into stale
      from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
     where i.account = inv.account and pa.channel = 'card_page' and pa.status = 'pending';
    if stale is not null then return jsonb_build_object('verify', stale); end if;
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

create or replace function billing.apply_payment(p_reference text, p_tx jsonb, p_at timestamptz default now())
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
end $$;

create or replace function billing.run_one(p_sub uuid, p_at timestamptz)
returns jsonb language plpgsql set search_path = billing, pg_temp as $$
declare
  s billing.subscriptions;
  m billing.markets;
  inv billing.invoices;
  pm billing.payment_methods;
  att billing.payment_attempts;
  due_from timestamptz;
  tz text;
  cut timestamptz;
begin
  select * into s from billing.subscriptions where id = p_sub;
  perform billing.lock_account(s.account);
  select * into s from billing.subscriptions where id = p_sub for update;
  if s.status not in ('active', 'past_due') then return null; end if;
  select mk.* into m from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = s.account;
  tz := coalesce((select a.time_zone from billing.accounts a where a.id = s.account), m.default_time_zone);
  cut := billing.past_due_cutoff(s.past_due_since, m.retry_days, tz);

  -- the clock had ended these already: no version bump, so a restart checkout stays good
  if s.cancel_at_period_end and s.period_end <= p_at then
    perform billing.end_sub(s.id, s.period_end, 'cancelled', p_at, 'job', false);
    return jsonb_build_object('step', 'ended', 'reason', 'cancelled');
  end if;
  if s.status = 'past_due' and p_at >= cut then
    -- a payment made before the cutoff may still land (or its page is not verified yet: this
    -- run's verify comes after): the next run looks again, at most a day after the cutoff
    if billing.plan_ended_held(s.account, s.id::text, p_at) then return null; end if;
    perform billing.end_sub(s.id, cut, 'unpaid', p_at, 'job', false);
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
  -- an unanswered charge, a card page on a replaced bill): nothing is charged again until it
  -- is settled or verified
  if exists (select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
              where i.account = s.account
                and ((i.status = 'open' and pa.status in ('created', 'pending', 'unknown'))
                     or (pa.channel = 'card_page' and pa.status = 'pending'))) then
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

create or replace function billing.outbox_on_attempt()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
declare inv billing.invoices;
begin
  if new.status = 'failed' and (tg_op = 'INSERT' or old.status is distinct from 'failed')
     and coalesce(new.gateway_response, '') not like 'copied: %' and not new.hard_decline
     -- the owner's own card page shows its result on screen: no email (0248)
     and new.channel in ('saved_card', 'none') then
    select * into inv from billing.invoices where id = new.invoice;
    if inv.kind = 'renewal' and new.channel = 'none' then
      -- no card to charge on the due date: the payment is due, not failed
      perform billing.outbox_put(inv.account, 'payment_due', inv.id, new.id::text, 'payment_due:' || inv.id,
                                 coalesce(new.settled_at, new.created_at), null, coalesce(new.settled_at, new.created_at));
    elsif inv.kind = 'renewal' then
      perform billing.outbox_put(inv.account, 'payment_failed', inv.id, new.id::text, 'payment_failed:' || new.id,
                                 coalesce(new.settled_at, new.created_at), null, coalesce(new.settled_at, new.created_at));
    end if;
  end if;
  return null;
end $$;

create or replace function billing.outbox_on_sub()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
begin
  if new.status = 'ended' and old.status is distinct from 'ended' then
    -- keyed and stamped with this ending, so a plan brought back that ends again has its own email
    insert into billing.outbox (account, key, ref, ended_at, dedupe_key, not_before, created_at)
    select new.account, 'plan_ended', new.id::text, new.ended_at,
           'plan_ended:' || new.id || ':' || (extract(epoch from new.ended_at) * 1000)::bigint,
           greatest(new.ended_at, now()), now()
     where new.account is not null
    on conflict (dedupe_key) do nothing;
  end if;
  return null;
end $$;

create or replace function billing.outbox_guard(o billing.outbox, p_at timestamptz)
returns text language plpgsql stable set search_path = billing, pg_temp as $$
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
      if not exists (select 1 from billing.plants p where p.id = o.ref::bigint and p.history_purged_at is not null) then
        return 'history back';
      end if;
  end case;
  return null;
end $$;

create or replace function billing.outbox_take(p_limit int default 50, p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  o billing.outbox;
  why text;
  out jsonb := '[]';
  inv billing.invoices;
  att billing.payment_attempts;
  pm billing.payment_methods;
  u record;
begin
  -- before the switch the old emails still go; these wait and go once it is on
  if not billing.is_live() then return '[]'::jsonb; end if;
  for o in select * from billing.outbox
            where status = 'queued' and not_before <= p_at and (claimed_until is null or claimed_until <= p_at)
              -- held, not dropped: a renewal paid before the cutoff may still be answered (0248)
              and not case when key = 'plan_ended' then billing.plan_ended_held(account, ref, p_at) else false end
            order by not_before, id limit p_limit for update skip locked loop
    why := billing.outbox_guard(o, p_at);
    if why is not null then
      update billing.outbox set status = 'dropped', drop_reason = why, claimed_until = null where id = o.id;
      continue;
    end if;
    select au.id, au.email, ep.unsub_token into u
      from billing.accounts a join auth.users au on au.id = a.user_id
      left join public.email_prefs ep on ep.user_id = au.id where a.id = o.account;
    if u.email is null then
      update billing.outbox set status = 'dropped', drop_reason = 'no email', claimed_until = null where id = o.id;
      continue;
    end if;
    inv := null; att := null; pm := null;
    if o.invoice is not null then
      select * into inv from billing.invoices where id = o.invoice;
      select * into att from billing.payment_attempts where invoice = inv.id and status in ('success', 'failed')
       order by (status = 'success') desc, created_at desc limit 1;
      -- a failed or refused try's email names that try's card; card_update rows queued before
      -- 0248 have no ref: the latest refused saved-card try on the bill
      if o.key in ('payment_failed', 'card_update', 'payment_due') then
        select * into att from billing.payment_attempts where invoice = inv.id and id::text = o.ref;
        if att.id is null and o.key = 'card_update' then
          select * into att from billing.payment_attempts where invoice = inv.id and channel = 'saved_card' and hard_decline
           order by created_at desc limit 1;
        end if;
      end if;
      if att.payment_method is not null then select * into pm from billing.payment_methods where id = att.payment_method; end if;
    end if;
    update billing.outbox set claimed_until = p_at + interval '5 minutes', tries = tries + 1 where id = o.id;
    out := out || jsonb_build_array(jsonb_build_object(
      'id', o.id, 'key', o.key, 'user', u.id, 'email', u.email,
      -- a reminder always carries its unsubscribe link: the settings row is made if missing
      'unsub_token', case when (select reminder from billing.outbox_kinds where key = o.key)
                          then public.email_unsub_token(u.id) else u.unsub_token end,
      'reminder', (select reminder from billing.outbox_kinds where key = o.key),
      'state', billing.screen_state(o.account, p_at),
      -- the frozen bill a receipt reads
      'bill', case when inv.id is not null then jsonb_build_object(
                'kind', inv.kind, 'plan', inv.plan, 'plan_name', inv.plan_name,
                'interval', inv.interval, 'amount_minor', inv.amount_minor, 'currency', inv.currency,
                'next_amount_minor', inv.plan_amount_minor + inv.extra_places * inv.extra_place_minor,
                'period_start', inv.period_start, 'period_end', inv.period_end, 'paid_at', inv.paid_at,
                'reference', att.reference, 'card_type', pm.card_type, 'last4', pm.last4) end,
      'refund', (select jsonb_build_object('amount_minor', coalesce(r.amount_minor, pa.amount_minor), 'currency',
                         coalesce(r.currency, pa.currency), 'reference', r.reference, 'reason', r.reason,
                         'paid_at', pa.settled_at, 'paid_minor', pa.amount_minor,
                         -- the card the refunded payment came from, not the one saved now
                         'card_type', rpm.card_type, 'last4', rpm.last4)
                   from billing.refunds r left join billing.payment_attempts pa on pa.id = r.attempt
                   left join billing.payment_methods rpm on rpm.id = pa.payment_method
                  where o.key = 'refund' and r.id = o.ref::uuid),
      -- a plan's end: its date, why, and whether a renewal payment was never answered
      'ended', case when o.key = 'plan_ended' then billing.plan_ended_facts(o) end,
      'event', (select jsonb_build_object('kind', e.kind, 'before', e.before, 'after', e.after)
                  from billing.account_events e where o.key in ('change_booked', 'change_undone') and e.id = o.ref::bigint),
      'plant', (select jsonb_build_object('id', p.id, 'name', coalesce((select lp.plant_name from billing.login_plants lp
                         join billing.logins l on l.id = lp.login where l.account = o.account and lp.plant = p.id limit 1),
                         (select pu.plant_name from public.plant_users pu where pu.plant_id = p.id and pu.user_id = u.id limit 1)))
                  from billing.plants p where o.key = 'history_deleted' and p.id = o.ref::bigint)));
  end loop;
  return out;
end $$;

create or replace function public.billing_v2(p_cmd text, p_args jsonb default '{}')
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
    when 'begin_attempt'    then billing.begin_attempt((p_args->>'invoice')::uuid, p_args->>'channel', now(), acc)
    when 'renewal_pages'    then billing.renewal_pages(acc)
    when 'verify_unanswered' then billing.verify_unanswered(p_args->>'reference')
    when 'attempt_page'     then coalesce(billing.attempt_page(p_args->>'reference', p_args->>'url'), '{}'::jsonb)
    when 'record_refund'    then billing.record_refund((p_args->>'refund')::uuid, p_args->>'error', p_args->>'provider_id')
    when 'record_refund_event' then billing.record_refund_event(p_args->>'reference', p_args->>'status', p_args->>'provider_id',
                                   (p_args->>'amount')::int, p_args->>'reason', now(), p_args->>'provider_ref')
    when 'record_dispute'   then billing.record_dispute(p_args->>'reference', p_args->>'event', p_args->>'status',
                                   (p_args->>'lost')::boolean, (p_args->>'amount')::int, now(), p_args->>'dispute_id')
    when 'event_begin'      then billing.event_begin(p_args->>'provider', p_args->>'type', p_args->>'entity', p_args->>'status', p_args->'payload')
    when 'event_done'       then (select '{}'::jsonb from (select billing.event_done((p_args->>'id')::bigint, p_args->>'error')) x)
    when 'run'              then billing.run()
    -- who opened the try, and the bill it pays (the paid message and its count)
    when 'attempt_user'     then (select jsonb_build_object('user', a.user_id, 'kind', i.kind, 'plan', i.plan,
                                   'plan_name', i.plan_name, 'interval', i.interval,
                                   'changed', i.kind = 'renewal' and i.plan is distinct from
                                     (select x.plan from billing.invoices x where x.subscription = i.subscription
                                         and x.status = 'paid' and x.kind in ('purchase', 'renewal', 'upgrade')
                                         and x.id <> i.id and x.period_start < i.period_start
                                       order by x.period_start desc, x.paid_at desc limit 1))
                                   from billing.payment_attempts pa
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
grant select on all tables in schema billing to service_role;

notify pgrst, 'reload schema';
