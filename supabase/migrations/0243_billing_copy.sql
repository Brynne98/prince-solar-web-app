-- ============================================================================
-- 0243 — billing redesign phase 1: copy today's accounts into the new tables
--        (SOLAR-641).
--
-- One function, NOT run by this migration. Run it once at switch-over
-- (DEPLOY.md, "Billing switch-over"): it empties the billing tables it fills and
-- copies fresh, so a second run gives the same rows. It refuses once the new
-- payment tables hold an invoice. The state test runs it on made-up rows.
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
--                  row is not paused.
--   subscriptions  private.billing home/family, not comped: amounts from
--                  billing_amount (cents), dates at midnight in Johannesburg.
--                  A plan that ended (plan 'free', ended_at set) becomes an ended
--                  row from its last paid charge.
--   grants         comped accounts: places = billing_room.
--   payment_methods the saved card (private.billing.card, card_email), so renewals
--                  go on charging it. The table comes in 0244; this body only runs
--                  after every migration is in.
-- ============================================================================

create function billing.copy_from_old()
returns jsonb language plpgsql security definer set search_path = billing, public, private, pg_temp as $$
declare
  tz constant text := 'Africa/Johannesburg';
  out jsonb;
  paid boolean := false;
begin
  if to_regclass('billing.invoices') is not null then
    execute 'select exists (select 1 from billing.invoices)' into paid;
  end if;
  if paid then
    raise exception 'billing copy refused: the new tables already hold payments' using errcode = '55000';
  end if;
  delete from billing.payment_methods;
  delete from billing.seats;
  delete from billing.plant_claims;
  delete from billing.login_plants;
  delete from billing.grants;
  delete from billing.subscriptions;
  delete from billing.logins;
  delete from billing.accounts;
  delete from billing.plants;

  insert into billing.accounts (user_id, market, trial_started_at, trial_ends_at, created_at)
  select u.id, 'ZA', fw.started, greatest(private.week_ends(u.id), fw.started), u.created_at
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

  insert into billing.plant_claims (plant, account, claimed_at)
  select pu.plant_id, a.id, pu.linked_at
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

  insert into billing.grants (account, places, reason, starts_at)
  select a.id, public.billing_room(b.plan, b.extra_plants), 'comped', b.created_at
    from private.billing b join billing.accounts a on a.user_id = b.user_id
   where b.comped and not exists (select 1 from billing.grants g where g.account = a.id);

  insert into billing.payment_methods (account, provider, customer_code, auth_ref, auth_email, reusable, signature,
                                       card_type, last4, exp_month, exp_year, active, created_at)
  select a.id, 'paystack', b.card->>'customer_code', b.card->>'authorization_code', b.card_email, true, b.card->>'signature',
         b.card->>'card_type', b.card->>'last4', nullif(b.card->>'exp_month', '')::smallint,
         nullif(b.card->>'exp_year', '')::smallint, true, b.created_at
    from private.billing b join billing.accounts a on a.user_id = b.user_id
   where b.card->>'authorization_code' is not null and coalesce((b.card->>'reusable')::boolean, true)
  on conflict (provider, auth_ref) do nothing;

  select jsonb_build_object(
    'accounts', (select count(*) from billing.accounts),
    'cards', (select count(*) from billing.payment_methods),
    'logins', (select count(*) from billing.logins),
    'plants', (select count(*) from billing.plants),
    'login_plants', (select count(*) from billing.login_plants),
    'plant_claims', (select count(*) from billing.plant_claims),
    'seats', (select count(*) from billing.seats),
    'subscriptions', (select count(*) from billing.subscriptions),
    'grants', (select count(*) from billing.grants)) into out;
  return out;
end $$;
revoke all on function billing.copy_from_old() from public, anon, authenticated;

