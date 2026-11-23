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
--   past due       the unpaid period is the one from past_due_since (the old run moved
--                  next_billing_date on before charging): period_end = past_due_since.
--                  Each gets its renewal bill and a failed day-0 try at past_due_since, so
--                  the retries keep their days.
--   subscriptions  private.billing home/family, not comped: amounts from
--                  billing_amount (cents), dates at midnight in Johannesburg. period_start
--                  is billing_step(period_end, -1) on the billing day (31 Jan, 28 Feb, 31 Mar).
--                  A plan that ended (plan 'free', ended_at set) becomes an ended
--                  row from its last paid charge.
--   grants         comped accounts: places = billing_room.
--   payment_methods the saved card (private.billing.card, card_email), so renewals
--                  go on charging it. The table comes in 0244; this body only runs
--                  after every migration is in.
--   old charges    private.billing_charges still open, or settled in the last 120 days
--                  (a dispute's window), and at any age one with a refund not done, a
--                  dispute not resolved or a lost dispute still owed: each becomes a bill
--                  and a try with the same reference, so a Paystack answer or a /verify
--                  after the switch finds it.
--                  Open: start -> purchase, upgrade -> upgrade on the running plan (its
--                  plants: the seats open now plus the ones it adds, to the plan's places;
--                  two for the same plan share one bill), renewal/settle -> the plan's
--                  renewal bill, card -> card_check; applied under the new rules, or refunded
--                  if stale there. Monthly to yearly (a 'switch' on the same plan, or an
--                  upgrade to a bigger plan yearly) -> an upgrade bill on yearly terms:
--                  paid, the same plan runs yearly to a year after its billing date, a bigger
--                  plan runs yearly from the payment (apply_upgrade). An open charge with no
--                  plan to put it on is a bill nothing applies (stale).
--                  Settled: a paid, refunded (not_applied) or failed try, answered 'again'.
--                  A paid renewal or start keeps its plan and period, so a reversal after
--                  the switch ends that period as designed. A refund not done -> a refunds
--                  row (asked: pending; else due and retried; 7 tries or hello@ told:
--                  failed, by hand). An open dispute -> dispute_open on the try; a lost
--                  dispute still owed -> amount_owed_minor on its bill.
--                  At any age: the paid charge that bought the running plan's current period
--                  (a yearly plan's renewal, start, switch or upgrade), linked to that plan and
--                  period, and any charge with a refund not done.
--                  Their tries say 'copied: ...', so a rerun is still allowed.
-- ============================================================================

-- An old paid charge that bought this plan's current period: a renewal or settle due on its
-- start, the start made on it, a switch whose year starts on it, an upgrade paid inside it.
create function billing.copy_funds_period(p_kind text, p_due date, p_created date, p_billing_date date,
                                          p_paid timestamptz, s billing.subscriptions)
returns boolean language sql stable as $$
  select coalesce(case p_kind
    when 'renewal' then p_due::timestamp at time zone 'Africa/Johannesburg' = s.period_start
    when 'settle' then p_due::timestamp at time zone 'Africa/Johannesburg' = s.period_start
    when 'start' then p_created::timestamp at time zone 'Africa/Johannesburg' = s.period_start
    when 'switch' then p_billing_date::timestamp at time zone 'Africa/Johannesburg' = s.period_start
    when 'upgrade' then p_paid >= s.period_start and p_paid < s.period_end end, false)
$$;
revoke all on function billing.copy_funds_period(text, date, date, date, timestamptz, billing.subscriptions) from public, anon, authenticated;

create function billing.copy_from_old()
returns jsonb language plpgsql security definer set search_path = billing, public, private, pg_temp as $$
declare
  tz constant text := 'Africa/Johannesburg';
  -- not the text of a failed old charge ('copied: failed before ...'), so the counts below stay apart
  seed constant text := 'copied: past due at the switch-over';
  out jsonb;
  paid boolean := false;
  r record;
  inv record;                                    -- billing.invoices (0244 comes after this file)
  review int := 0;
  osub billing.subscriptions;                    -- old charges: o* names, clear of the queries' aliases
  opr record;
  okind text;
  oiv text;
  och text;
  odue timestamptz;
  oinv uuid;
  oplants bigint[];
  oatt uuid;
  ostatus text;
  odone boolean;
  oopen boolean;
  oyear boolean;
  ocur boolean;
  oreason text;
begin
  -- anything but this copy's own seed tries (below) means real money moved here
  if to_regclass('billing.invoices') is not null then
    -- the copy's own tries say 'copied: ...'; any answer since replaces that text
    execute $q$select exists (select 1 from billing.invoices i where i.status <> 'open'
                                 and not exists (select 1 from billing.payment_attempts pa where pa.invoice = i.id
                                                    and pa.gateway_response like 'copied: %'))
                 or exists (select 1 from billing.payment_attempts where coalesce(gateway_response, '') not like 'copied: %')
                 or exists (select 1 from billing.refunds where coalesce(last_error, '') not like 'copied: %'
                                                             or updated_at <> created_at)
                 or exists (select 1 from billing.payment_events)$q$
      into paid;
  end if;
  if paid then
    raise exception 'billing copy refused: the new tables already hold payments' using errcode = '55000';
  end if;
  if to_regclass('billing.invoices') is not null then
    execute 'delete from billing.refunds';
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
         public.billing_amount(b.plan, d.per, 0, b.offer_id) * 100,
         (public.billing_amount(b.plan, d.per, 1, b.offer_id) - public.billing_amount(b.plan, d.per, 0, b.offer_id)) * 100,
         case when d.prepaid then case when b.plan = 'family' then coalesce(b.next_extra_plants, b.extra_plants) else 0 end
              else b.extra_plants end,
         b.offer_id, b.state,
         least(coalesce((select min(c.created_at) from private.billing_charges c
                          where c.user_id = b.user_id and c.status = 'paid'), b.created_at), ps),
         bday, ps, pe,
         (b.past_due_since::timestamp at time zone tz),
         coalesce(b.next_plan = 'free', false),
         -- a paid year: its switch is done; only a plan change booked on top would be next
         case when b.next_plan in ('home', 'family') or (b.next_period is not null and not d.prepaid) then
           (select p.id from billing.prices p
             where p.plan = coalesce(nullif(b.next_plan, 'free'), b.plan) and p.market = 'ZA'
               and p.interval = case coalesce(b.next_period, b.period) when 'yearly' then 'year' else 'month' end
               and p.offer is not distinct from b.offer_id and p.active_until is null) end,
         case when not d.prepaid then b.next_extra_plants end, null
    from private.billing b
    join billing.accounts a on a.user_id = b.user_id
    -- past due: the unpaid period ends at past_due_since (next_billing_date is a period on)
    -- a switch to yearly already paid (0138, prepaid_on = next_billing_date): the year from the
    -- billing date is paid, so the plan copies on yearly terms to a year after it (the month
    -- running now is its first part) and nothing is charged on the billing date
    cross join lateral (select coalesce(b.billing_day, extract(day from b.next_billing_date)::smallint) bday,
                               case when b.state = 'past_due' then coalesce(b.past_due_since, b.next_billing_date)
                                    else b.next_billing_date end ped,
                               coalesce(b.prepaid_on = b.next_billing_date and b.state = 'active', false) prepaid,
                               case when b.prepaid_on = b.next_billing_date and b.state = 'active' then 'yearly'
                                    else b.period end per) d
    cross join lateral (select case d.per when 'yearly' then 'year' else 'month' end iv,
                               (case when d.prepaid then public.billing_step(d.ped, 'yearly', d.bday, 1) else d.ped end
                                 ::timestamp at time zone tz) pe,
                               -- a paid year starts on the billing date it was paid for
                               ((case when d.prepaid then d.ped else public.billing_step(d.ped, b.period, d.bday, -1) end)
                                 ::timestamp at time zone tz) ps) v
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
               -- at any age: a refund not done, a dispute not resolved, a lost dispute still owed
               or (c.status = 'paid' and (c.kind = 'card' or c.error like 'refund%') and coalesce(c.refund_status, 'failed') <> 'done')
               or coalesce(c.refund_status, 'done') <> 'done'
               -- at any age: the paid charge that bought the running plan's current period (a
               -- yearly plan's can be a year old), so a reversal after the switch ends that period
               or (c.status = 'paid' and exists (select 1 from billing.subscriptions x where x.account = a.id
                     and x.status in ('active', 'past_due') and billing.copy_funds_period(c.kind, c.due_on, c.created_on, c.billing_date, coalesce(c.settled_at, c.created_at), x)))
               or (c.dispute is not null and not c.dispute_lost and c.dispute !~* '^(resolved?|won|lost|archived|closed)$')
               or c.dispute_owed
            order by c.created_at, c.reference loop
    okind := case r.kind when 'start' then 'purchase' when 'card' then 'card_check'
                     when 'upgrade' then 'upgrade' when 'switch' then 'upgrade' else 'renewal' end;
    och := case when r.kind = 'renewal' then 'saved_card' else 'card_page' end;
    oiv := case r.period when 'yearly' then 'year' else 'month' end;
    oinv := null;
    oplants := coalesce(r.plants, array(select se.plant from billing.seats se
                                      where se.account = r.account and se.closed_at is null order by se.plant));
    -- the account's plan row (running, else the ended one the copy made)
    select * into osub from billing.subscriptions x where x.account = r.account
     order by x.status in ('active', 'past_due') desc, x.started_at desc limit 1;
    if r.status = 'pending' then
      if osub.status not in ('active', 'past_due') then osub := null; end if;
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
      elsif okind = 'upgrade' and osub.status = 'active'
            -- the same interval; or monthly to yearly (a switch, or a bigger plan yearly): yearly terms
            and (oiv = osub.interval or (oiv = 'year' and osub.interval = 'month')) then
        opr := billing.price_keeping_offer(r.plan, 'ZA', oiv, osub.offer, r.created_at);
        -- the old charge names only the plants it adds: the seats open now come first, to the plan's places
        oplants := array(select y.p from (
                           select y2.p, y2.o, y2.t from (
                             select distinct on (z.p) z.p, z.o, z.t from (
                               select se.plant p, 0 o, se.chosen_at t from billing.seats se
                                where se.account = r.account and se.closed_at is null
                               union all select u.p, 1, null::timestamptz from unnest(coalesce(r.plants, '{}')) u (p)) z
                              order by z.p, z.o) y2
                            order by y2.o, y2.t, y2.p
                            limit (select pl.places from billing.plans pl where pl.code = r.plan)
                                  + coalesce(r.extra_plants, osub.extra_places)) y
                          order by y.p);
        if opr.id is not null then
          -- the same upgrade again (same plan, places, plants and amount): the same bill. Any
          -- other open upgrade is replaced, as billing.upgrade does: its bill is void, so a
          -- payment on its page is refunded (stale) and only the newest page applies
          select i.id into oinv from billing.invoices i
           where i.subscription = osub.id and i.kind = 'upgrade' and i.status = 'open'
             and i.amount_minor = r.amount * 100 and i.plants = oplants
             and i.period_key = extract(epoch from osub.period_start)::bigint || ':' || r.plan || '+'
                                || coalesce(r.extra_plants, osub.extra_places) || case when oiv <> osub.interval then ':' || oiv else '' end;
          if oinv is null then
            perform billing.replace_card_pages(array(select i.id from billing.invoices i
                                                      where i.subscription = osub.id and i.kind = 'upgrade' and i.status = 'open'), r.created_at);
            update billing.invoices set status = 'void' where subscription = osub.id and kind = 'upgrade' and status = 'open';
            insert into billing.invoices (account, subscription, kind, price, plan, interval, offer, extra_places,
                                          plan_amount_minor, extra_place_minor, amount_minor, tax_minor, currency,
                                          period_start, period_end, period_key, plants, created_at)
            values (r.account, osub.id, 'upgrade', opr.id, r.plan, oiv, osub.offer, coalesce(r.extra_plants, osub.extra_places),
                    opr.amount_minor, opr.extra_place_minor, r.amount * 100, opr.tax_minor, osub.currency, osub.period_start,
                    osub.period_end, extract(epoch from osub.period_start)::bigint || ':' || r.plan || '+'
                                     || coalesce(r.extra_plants, osub.extra_places) || case when oiv <> osub.interval then ':' || oiv else '' end,
                    oplants, r.created_at)
            returning id into oinv;
          end if;
        end if;
      end if;
    end if;
    ostatus := case when r.status = 'pending' then case och when 'saved_card' then 'unknown' else 'pending' end
                    when r.status = 'failed' then 'failed'
                    -- paid but not applied (refund%), or refunded before it was reported: refunded
                    when r.kind <> 'card' and r.error like 'refund%' then 'not_applied'
                    else 'success' end;
    -- the paid charge that bought the running plan's current period: that plan and period
    ocur := ostatus = 'success' and osub.status in ('active', 'past_due') and billing.copy_funds_period(r.kind, r.due_on, r.created_on, r.billing_date, coalesce(r.settled_at, r.created_at), osub);
    if oinv is null then
      -- a settled charge, or an open one nothing under the new rules applies (refunded as stale if paid).
      -- A paid renewal or start keeps its plan and period, so a reversal ends that period. So
      -- does the paid switch to the yearly plan copied as a paid year: its bill is that year.
      oyear := ocur or (ostatus = 'success' and r.kind = 'switch' and r.period = 'yearly' and osub.interval = 'year'
               and r.billing_date is not null and osub.period_start = r.billing_date::timestamp at time zone tz);
      insert into billing.invoices (account, subscription, kind, status, plan, interval, offer, extra_places, amount_minor,
                                    currency, period_start, period_end, plants, created_at, paid_at)
      values (r.account, case when (ostatus = 'success' and r.kind in ('renewal', 'settle', 'start')) or oyear then osub.id end, okind,
              case when r.status = 'pending' then 'open' when ostatus = 'success' then 'paid' else 'void' end,
              r.plan, oiv, r.offer_id, coalesce(r.extra_plants, 0), r.amount * 100, 'ZAR',
              case when oyear then osub.period_start
                   when ostatus = 'success' and osub.id is not null and r.kind in ('renewal', 'settle', 'start') then
                coalesce(case when r.kind = 'start' then r.created_on end, r.due_on)::timestamp at time zone tz end,
              case when oyear then osub.period_end
                   when ostatus = 'success' and osub.id is not null and r.kind in ('renewal', 'settle', 'start') then
                public.billing_step(coalesce(case when r.kind = 'start' then r.created_on end, r.due_on), r.period,
                  case when r.kind = 'start' then extract(day from r.created_on)::int else osub.billing_day end, 1)
                ::timestamp at time zone tz end,
              oplants, r.created_at,
              case when ostatus = 'success' then coalesce(r.settled_at, r.created_at) end)
      returning id into oinv;
    end if;
    -- an open try: no lease, so the next billing run asks Paystack about it
    oopen := r.dispute is not null and not r.dispute_lost and r.dispute !~* '^(resolved?|won|lost|archived|closed)$';
    insert into billing.payment_attempts (invoice, reference, provider, channel, amount_minor, currency, status,
                                          claimed_until, gateway_response, dispute_status, dispute_open, dispute_resolved_at,
                                          created_at, settled_at)
    values (oinv, r.reference, 'paystack', och, r.amount * 100, 'ZAR', ostatus,
            case when r.status = 'pending' then now() end,
            'copied: ' || r.status || ' before the switch-over', r.dispute, oopen,
            case when r.dispute is not null and not oopen then coalesce(r.refunded_at, now()) end,
            r.created_at, case when r.status <> 'pending' then coalesce(r.settled_at, r.created_at) end)
    returning id into oatt;
    -- a lost dispute still owed (the old run had not charged it yet): owed on its bill
    if r.dispute_owed then
      update billing.invoices set amount_owed_minor = coalesce(r.refunded_cents, r.amount * 100) where id = oinv;
    end if;
    -- a refund asked or owed: retried under the new rules; one done stays on record. A refund
    -- Paystack reported while the charge was still pending (0197): the payment never applies,
    -- so a success on that reference later finds this refund and is not applied (stale)
    if (r.status = 'paid' and not r.dispute_lost
        and (r.kind = 'card' or r.error like 'refund%' or r.refund_status is not null))
       or (r.status = 'pending' and r.refund_status is not null) then
      odone := r.refund_status = 'done';
      -- 7 tries made or hello@ told, or a hand refund: by hand (manual), never sent automatically
      oreason := case when r.refund_tries >= 7 or r.refund_alerted then 'manual'
                      -- a failed refund on a payment never confirmed: by hand, not sent blind
                      when r.status = 'pending' then case when r.refund_status = 'failed' then 'manual' else 'stale' end
                      when not (r.kind = 'card' or coalesce(r.error, '') like 'refund%') then 'manual'
                      when r.kind = 'card' then 'card_check' else 'stale' end;
      insert into billing.refunds (attempt, reference, account, amount_minor, currency, reason, status, tries,
                                   last_error, created_at, updated_at)
      values (oatt, r.reference, r.account, r.refunded_cents, 'ZAR', oreason,
              case when odone then 'processed' when r.refund_status = 'asked' then 'pending'
                   when oreason = 'manual' then 'failed' else 'due' end,
              r.refund_tries, 'copied: ' || coalesce(r.refund_status, 'owed') || ' before the switch-over', now(), now());
    end if;
  end loop;
  -- every settled old reference, at any age: a success Paystack sends again for an old paid
  -- one is answered as already applied (apply_payment), never refunded as unknown
  delete from billing.old_references;
  insert into billing.old_references (reference, account, status, settled_at, kind, plan, interval, amount_minor, channel)
  select c.reference, a.id, c.status, coalesce(c.settled_at, c.created_at),
         case c.kind when 'start' then 'purchase' when 'card' then 'card_check'
                     when 'upgrade' then 'upgrade' when 'switch' then 'upgrade' else 'renewal' end,
         case when c.kind <> 'card' and c.plan in ('home', 'family') then c.plan end,
         case c.period when 'yearly' then 'year' else 'month' end, c.amount * 100,
         case when c.kind = 'renewal' then 'saved_card' else 'card_page' end
    from private.billing_charges c left join billing.accounts a on a.user_id = c.user_id
   where c.status <> 'pending';

  -- an open purchase or upgrade applies only to the account as copied
  update billing.invoices i set expected_version = a.version from billing.accounts a
   where a.id = i.account and i.status = 'open' and i.kind in ('purchase', 'upgrade');

  -- emails the copied rows set off (an old refund): the old billing sent its own
  delete from billing.outbox;

  select jsonb_build_object(
    'accounts', (select count(*) from billing.accounts),
    'refunds', (select count(*) from billing.refunds),
    'refunds_to_send', (select count(*) from billing.refunds where status = 'due'),
    'disputes_open', (select count(*) from billing.payment_attempts where dispute_open),
    'owed', (select count(*) from billing.invoices where amount_owed_minor > 0),
    'old_references', (select count(*) from billing.old_references),
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

