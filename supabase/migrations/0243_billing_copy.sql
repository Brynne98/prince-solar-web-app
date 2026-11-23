-- ============================================================================
-- 0243 — billing redesign phase 1: copy today's accounts into the new tables
--        (SOLAR-641).
--
-- One function, NOT run by this migration. Run it once at switch-over
-- (DEPLOY.md, "Billing switch-over"): it empties the billing tables it fills and
-- copies fresh, so a second run gives the same rows. It refuses once the new
-- payment tables hold an invoice. The state test runs it on made-up rows.
-- A rerun keeps each account's id and clears only the account_events rows the copy
-- wrote itself (actor 'copy').
-- The old tables stay untouched and in use. Nothing old reads the new tables.
--
--   accounts       every auth user; trial from private.free_week_logins
--                  (start = first week row, end = private.week_ends).
--   logins         private.sunsynk_accounts kind 'login', same id, same vault id.
--                  'active' -> ok, anything else -> needs_reconnect.
--   plants         every plant in plant_users, plant_picks or plant_week.
--                  trial_used_at = plant_week.started_at; trial_used_by = the
--                  linked account whose week began closest to it.
--   login_plants   plant_users rows reached by a login (not via a share).
--   plant_claims   live share claims (via_share, share_gone_at null).
--   seats          plant_picks held (the tick holds a place), whose plant_users
--                  row is not paused. A booked downgrade's plants_to_remove are marked
--                  to drop; still too many for the next plan: flagged copy_needs_review.
--   past due       each copied past_due plan gets its renewal bill and a failed day-0
--                  try at past_due_since, so the retries keep their days.
--   subscriptions  private.billing home/family, not comped: amounts from
--                  billing_amount (cents), dates at midnight in Johannesburg.
--                  A plan that ended (plan 'free', ended_at set) becomes an ended
--                  row from its last paid charge.
--   grants         comped accounts: places = billing_room.
--   payment_methods the saved card (private.billing.card, card_email), so renewals
--                  go on charging it. The table comes in 0244; this body only runs
--                  after every migration is in.
--   old charges    private.billing_charges still open, or settled in the last 120 days
--                  (a dispute's window): each becomes a bill and a try with the same
--                  reference, so a Paystack answer or a /verify after the switch finds it.
--                  Open: start -> purchase, upgrade -> upgrade on the running plan,
--                  renewal/settle -> the plan's renewal bill, card -> card_check; applied
--                  under the new rules, or refunded if stale there. A yearly switch, or an
--                  open charge with no plan to put it on, is a bill nothing applies (stale).
--                  Settled: a paid, refunded (not_applied) or failed try, answered 'again'.
--                  Their tries say 'copied: ...', so a rerun is still allowed.
-- ============================================================================

create function billing.copy_from_old()
returns jsonb language plpgsql security definer set search_path = billing, public, private, pg_temp as $$
declare
  tz constant text := 'Africa/Johannesburg';
  seed constant text := 'copied: failed before the switch-over';
  out jsonb;
  paid boolean := false;
  r record;
  inv record;                                    -- billing.invoices (0244 comes after this file)
  review int := 0;
  osub record;                                   -- old charges: o* names, clear of the queries' aliases
  opr record;
  okind text;
  oiv text;
  och text;
  odue timestamptz;
  oinv uuid;
  oplants bigint[];
begin
  -- anything but this copy's own seed tries (below) means real money moved here
  if to_regclass('billing.invoices') is not null then
    -- the copy's own tries say 'copied: ...'; any answer since replaces that text
    execute $q$select exists (select 1 from billing.invoices i where i.status <> 'open'
                                 and not exists (select 1 from billing.payment_attempts pa where pa.invoice = i.id
                                                    and pa.gateway_response like 'copied: %'))
                 or exists (select 1 from billing.payment_attempts where coalesce(gateway_response, '') not like 'copied: %')
                 or exists (select 1 from billing.refunds) or exists (select 1 from billing.payment_events)$q$
      into paid;
  end if;
  if paid then
    raise exception 'billing copy refused: the new tables already hold payments' using errcode = '55000';
  end if;
  if to_regclass('billing.invoices') is not null then
    execute 'delete from billing.payment_attempts';
    execute 'delete from billing.outbox';
    execute 'delete from billing.invoices';
  end if;
  -- only the events this copy wrote (actor 'copy'); the poller's and the commands' stay,
  -- and the accounts keep their ids below, so those events still point at them
  delete from billing.account_events where actor = 'copy';
  drop table if exists pg_temp.copy_ids;
  create temp table copy_ids as select user_id, id from billing.accounts;
  delete from billing.payment_methods;
  delete from billing.seats;
  delete from billing.plant_claims;
  delete from billing.login_plants;
  delete from billing.grants;
  delete from billing.subscriptions;
  delete from billing.logins;
  delete from billing.accounts;
  delete from billing.plants;

  insert into billing.accounts (id, user_id, market, trial_started_at, trial_ends_at, created_at)
  select coalesce((select c.id from pg_temp.copy_ids c where c.user_id = u.id), gen_random_uuid()),
         u.id, 'ZA', fw.started, greatest(private.week_ends(u.id), fw.started), u.created_at
    from auth.users u
    left join lateral (select min(f.started_at) started from private.free_week_logins f where f.user_id = u.id) fw on true
  on conflict (user_id) do nothing;

  insert into billing.logins (id, account, brand, username, secret_ref, status, created_at)
  select s.id, a.id, s.provider, s.sunsynk_username, s.refresh_secret_id,
         case s.status when 'active' then 'ok' else 'needs_reconnect' end, s.linked_at
    from private.sunsynk_accounts s join billing.accounts a on a.user_id = s.user_id
   where s.kind = 'login'
  on conflict (id) do nothing;

  insert into billing.plants (id, brand, external_id, trial_used_at, trial_used_by)
  select x.plant_id,
         coalesce((select s.provider from public.plant_users pu join private.sunsynk_accounts s on s.id = pu.account_id
                    where pu.plant_id = x.plant_id limit 1), 'sunsynk'),
         x.plant_id::text,
         pw.started_at,
         case when pw.started_at is not null then
           (select a.id from public.plant_users pu
              join private.free_week_logins f on f.user_id = pu.user_id
              join billing.accounts a on a.user_id = pu.user_id
             where pu.plant_id = x.plant_id
             order by abs(extract(epoch from f.started_at - pw.started_at)) limit 1) end
    from (select plant_id from public.plant_users
          union select plant_id from private.plant_picks
          union select plant_id from private.plant_week) x
    left join private.plant_week pw on pw.plant_id = x.plant_id
  on conflict (id) do nothing;

  insert into billing.login_plants (login, plant, plant_name)
  select pu.account_id, pu.plant_id, pu.plant_name
    from public.plant_users pu join billing.logins l on l.id = pu.account_id
   where not pu.via_share
  on conflict do nothing;

  insert into billing.plant_claims (plant, account, claimed_at, plant_name)
  select pu.plant_id, a.id, pu.linked_at, pu.plant_name
    from public.plant_users pu join billing.accounts a on a.user_id = pu.user_id
   where pu.via_share and pu.share_gone_at is null
  on conflict do nothing;

  insert into billing.seats (account, plant, chosen_at)
  select a.id, pk.plant_id, pk.picked_at
    from private.plant_picks pk
    join billing.accounts a on a.user_id = pk.user_id
    join public.plant_users pu on pu.user_id = pk.user_id and pu.plant_id = pk.plant_id
   where pk.held and not pu.paused
     and not exists (select 1 from billing.seats s where s.account = a.id and s.plant = pk.plant_id and s.closed_at is null);

  -- running plans
  insert into billing.subscriptions (account, price, plan, currency, interval, amount_minor, extra_place_minor,
                                     extra_places, offer, status, started_at, billing_day, period_start, period_end,
                                     past_due_since, cancel_at_period_end, next_price, next_extra_places, ended_at)
  select a.id,
         (select p.id from billing.prices p where p.plan = b.plan and p.market = 'ZA' and p.interval = iv
             and p.offer is not distinct from b.offer_id and p.active_until is null),
         b.plan, 'ZAR', iv,
         public.billing_amount(b.plan, b.period, 0, b.offer_id) * 100,
         (public.billing_amount(b.plan, b.period, 1, b.offer_id) - public.billing_amount(b.plan, b.period, 0, b.offer_id)) * 100,
         b.extra_plants, b.offer_id, b.state,
         least(coalesce((select min(c.created_at) from private.billing_charges c
                          where c.user_id = b.user_id and c.status = 'paid'), b.created_at), pe - step),
         coalesce(b.billing_day, extract(day from b.next_billing_date)::smallint),
         pe - step, pe,
         (b.past_due_since::timestamp at time zone tz),
         coalesce(b.next_plan = 'free', false),
         case when b.next_plan in ('home', 'family') or b.next_period is not null then
           (select p.id from billing.prices p
             where p.plan = coalesce(nullif(b.next_plan, 'free'), b.plan) and p.market = 'ZA'
               and p.interval = case coalesce(b.next_period, b.period) when 'yearly' then 'year' else 'month' end
               and p.offer is not distinct from b.offer_id and p.active_until is null) end,
         b.next_extra_plants, null
    from private.billing b
    join billing.accounts a on a.user_id = b.user_id
    cross join lateral (select case b.period when 'yearly' then 'year' else 'month' end iv,
                               (b.next_billing_date::timestamp at time zone tz) pe,
                               case b.period when 'yearly' then interval '1 year' else interval '1 month' end step) v
   where b.plan in ('home', 'family') and not b.comped
     and not exists (select 1 from billing.subscriptions s where s.account = a.id);

  -- ended plans: the last paid charge says which plan it was
  insert into billing.subscriptions (account, plan, currency, interval, amount_minor, extra_places, offer, status,
                                     started_at, billing_day, period_start, period_end, ended_at)
  select a.id, c.plan, 'ZAR', case c.period when 'yearly' then 'year' else 'month' end, c.amount * 100,
         coalesce(c.extra_plants, 0), c.offer_id, 'ended',
         least(c.created_at, b.ended_at - interval '1 day'),
         extract(day from coalesce(c.billing_date, c.due_on))::smallint,
         least(c.created_at, b.ended_at - interval '1 day'), b.ended_at, b.ended_at
    from private.billing b
    join billing.accounts a on a.user_id = b.user_id
    cross join lateral (select * from private.billing_charges c
                         where c.user_id = b.user_id and c.status = 'paid' and c.plan in ('home', 'family')
                         order by c.created_at desc limit 1) c
   where b.plan = 'free' and b.ended_at is not null and not b.comped
     and not exists (select 1 from billing.subscriptions s where s.account = a.id);

  -- a failed card copied mid-window: its day-0 try, so the retries keep their days
  for r in select s.id, s.past_due_since from billing.subscriptions s where s.status = 'past_due' loop
    inv := billing.ensure_renewal(r.id, r.past_due_since);
    insert into billing.payment_attempts (invoice, reference, provider, channel, amount_minor, currency, status,
                                          gateway_response, created_at, settled_at)
    values (inv.id, billing.new_reference(), 'paystack', 'none', inv.amount_minor, inv.currency, 'failed', seed,
            r.past_due_since, r.past_due_since);
  end loop;
  -- a booked downgrade: the plants picked to go (plants_to_remove) are marked to drop; one
  -- whose kept plants still do not fit the next plan is flagged for support to pick
  -- only where the copied plan has a smaller one booked (a plan or fewer extra places): an old
  -- removal list on an account with nothing booked is not a drop
  update billing.seats se set drop_at_period_end = true
    from private.billing b join billing.accounts a on a.user_id = b.user_id
    join billing.subscriptions s on s.account = a.id and s.status in ('active', 'past_due')
   where se.account = a.id and se.closed_at is null and se.plant = any (b.plants_to_remove)
     and (s.next_price is not null or s.next_extra_places is not null);
  for r in select s.account, s.id from billing.subscriptions s
             left join billing.prices np on np.id = s.next_price
             join billing.plans npl on npl.code = coalesce(np.plan, s.plan)
            where s.status in ('active', 'past_due') and (s.next_price is not null or s.next_extra_places is not null)
              and (select count(*) from billing.seats se where se.account = s.account and se.closed_at is null
                      and not se.drop_at_period_end) > npl.places + coalesce(s.next_extra_places, s.extra_places) loop
    perform billing.log_event(r.account, now(), 'copy', 'copy_needs_review', null, jsonb_build_object('sub', r.id),
                              'booked downgrade: pick the plants to drop');
    review := review + 1;
  end loop;

  insert into billing.grants (account, places, reason, starts_at)
  select a.id, public.billing_room(b.plan, b.extra_plants), 'comped', b.created_at
    from private.billing b join billing.accounts a on a.user_id = b.user_id
   where b.comped and not exists (select 1 from billing.grants g where g.account = a.id);

  insert into billing.payment_methods (account, provider, customer_code, auth_ref, auth_email, reusable, signature,
                                       card_type, last4, exp_month, exp_year, active, created_at)
  select a.id, 'paystack', b.card->>'customer_code', b.card->>'authorization_code', coalesce(b.card_email, u.email), true, b.card->>'signature',
         b.card->>'card_type', b.card->>'last4', nullif(b.card->>'exp_month', '')::smallint,
         nullif(b.card->>'exp_year', '')::smallint, true, b.created_at
    from private.billing b join billing.accounts a on a.user_id = b.user_id join auth.users u on u.id = b.user_id
   where b.card->>'authorization_code' is not null and coalesce((b.card->>'reusable')::boolean, true)
  on conflict (provider, auth_ref) do nothing;

  -- old charges (see the header): the same reference on the new tables
  for r in select c.*, a.id account from private.billing_charges c join billing.accounts a on a.user_id = c.user_id
            where c.status = 'pending' or coalesce(c.settled_at, c.created_at) > now() - interval '120 days'
            order by c.created_at, c.reference loop
    okind := case r.kind when 'start' then 'purchase' when 'card' then 'card_check'
                     when 'upgrade' then 'upgrade' when 'switch' then 'upgrade' else 'renewal' end;
    och := case when r.kind = 'renewal' then 'saved_card' else 'card_page' end;
    oiv := case r.period when 'yearly' then 'year' else 'month' end;
    oinv := null;
    oplants := coalesce(r.plants, array(select se.plant from billing.seats se
                                      where se.account = r.account and se.closed_at is null order by se.plant));
    if r.status = 'pending' then
      select * into osub from billing.subscriptions x where x.account = r.account and x.status in ('active', 'past_due');
      if okind = 'renewal' and osub.id is not null then
        odue := r.due_on::timestamp at time zone tz;
        if osub.status = 'active' and osub.period_start = odue then
          -- the old run moved the billing date on before charging: that period is not paid yet
          update billing.subscriptions
             set period_end = odue,
                 period_start = public.billing_step(r.due_on, r.period, osub.billing_day, -1)::timestamp at time zone tz
           where id = osub.id returning * into osub;
        end if;
        if osub.period_end = odue then oinv := (billing.ensure_renewal(osub.id, r.created_at)).id; end if;
      elsif okind = 'purchase' then
        opr := billing.price_for(r.plan, 'ZA', oiv, r.offer_id, r.created_at);
        if opr.id is null then opr := billing.price_for(r.plan, 'ZA', oiv, null, r.created_at); end if;
        if opr.id is not null then
          insert into billing.invoices (account, kind, price, plan, interval, offer, extra_places, plan_amount_minor,
                                        extra_place_minor, amount_minor, tax_minor, currency, plants, created_at)
          values (r.account, 'purchase', opr.id, r.plan, oiv, opr.offer, coalesce(r.extra_plants, 0), opr.amount_minor,
                  opr.extra_place_minor, r.amount * 100, opr.tax_minor, 'ZAR', oplants, r.created_at)
          returning id into oinv;
        end if;
      elsif r.kind = 'upgrade' and osub.status = 'active' then
        opr := billing.price_keeping_offer(r.plan, 'ZA', osub.interval, osub.offer, r.created_at);
        if opr.id is not null then
          insert into billing.invoices (account, subscription, kind, price, plan, interval, offer, extra_places,
                                        plan_amount_minor, extra_place_minor, amount_minor, tax_minor, currency,
                                        period_start, period_end, period_key, plants, created_at)
          values (r.account, osub.id, 'upgrade', opr.id, r.plan, osub.interval, osub.offer, coalesce(r.extra_plants, osub.extra_places),
                  opr.amount_minor, opr.extra_place_minor, r.amount * 100, opr.tax_minor, osub.currency, osub.period_start,
                  osub.period_end, extract(epoch from osub.period_start)::bigint || ':' || r.plan || '+' || coalesce(r.extra_plants, osub.extra_places),
                  oplants, r.created_at)
          returning id into oinv;
        end if;
      end if;
    end if;
    if oinv is null then
      -- a settled charge, or an open one nothing under the new rules applies (refunded as stale if paid)
      insert into billing.invoices (account, kind, status, plan, interval, offer, extra_places, amount_minor, currency,
                                    plants, created_at, paid_at)
      values (r.account, okind,
              case when r.status = 'pending' then 'open' when r.status = 'paid' and r.refunded_at is null then 'paid' else 'void' end,
              r.plan, oiv, r.offer_id, coalesce(r.extra_plants, 0), r.amount * 100, 'ZAR', oplants, r.created_at,
              case when r.status = 'paid' and r.refunded_at is null then coalesce(r.settled_at, r.created_at) end)
      returning id into oinv;
    end if;
    -- an open try: no lease, so the next billing run asks Paystack about it
    insert into billing.payment_attempts (invoice, reference, provider, channel, amount_minor, currency, status,
                                          claimed_until, gateway_response, created_at, settled_at)
    values (oinv, r.reference, 'paystack', och, r.amount * 100, 'ZAR',
            case when r.status = 'pending' then case och when 'saved_card' then 'unknown' else 'pending' end
                 when r.status = 'failed' then 'failed' when r.refunded_at is null then 'success' else 'not_applied' end,
            case when r.status = 'pending' then now() end,
            'copied: ' || r.status || ' before the switch-over', r.created_at,
            case when r.status <> 'pending' then coalesce(r.settled_at, r.created_at) end);
  end loop;
  -- an open purchase or upgrade applies only to the account as copied
  update billing.invoices i set expected_version = a.version from billing.accounts a
   where a.id = i.account and i.status = 'open' and i.kind in ('purchase', 'upgrade');

  select jsonb_build_object(
    'accounts', (select count(*) from billing.accounts),
    'old_charges', (select count(*) from billing.payment_attempts where gateway_response like 'copied: %'
                                                               and gateway_response <> seed),
    'cards', (select count(*) from billing.payment_methods),
    'logins', (select count(*) from billing.logins),
    'plants', (select count(*) from billing.plants),
    'login_plants', (select count(*) from billing.login_plants),
    'plant_claims', (select count(*) from billing.plant_claims),
    'seats', (select count(*) from billing.seats),
    'subscriptions', (select count(*) from billing.subscriptions),
    'grants', (select count(*) from billing.grants),
    'past_due_seeded', (select count(*) from billing.payment_attempts where gateway_response = seed),
    'needs_review', review) into out;
  return out;
end $$;
revoke all on function billing.copy_from_old() from public, anon, authenticated;

