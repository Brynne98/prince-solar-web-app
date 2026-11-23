-- ============================================================================
-- 0247 — billing redesign phase 4: screens, logins and claims, emails (SOLAR-641).
--
-- Design: reports/billing-redesign-2026-11-22.md (sections 4 and 6, v2 should-fix,
-- Round 4). Nothing here changes what runs today: the old RPCs stay as they are until
-- the drop migration (supabase/after-switch-over, DEPLOY.md "Billing switch-over").
--
-- Screens
--   billing.screen_state(account, at)  account_state plus what a screen shows and the
--       state alone cannot carry: plan names, the account's clock and locale, the plan
--       prices this account would pay, its logins, its last bills, each plant's fate if
--       it goes (kept_elsewhere), and the dates a booked change brings. Worked out here,
--       never in the app or an email.
--   public.api_account_state()        the caller's own screen_state, nothing else.
--   public.api_choose_plants(plants)  the caller's set_chosen_plants (every switch).
--   public.api_plan_quote(plan, interval)  what a plan change would charge now and next.
--
-- Logins and claims (link-sunsynk, claim-share, through billing_v2)
--   link_login  the stored login's id, brand, username, vault id and plant list.
--   claim_plant a plant shared to our service login: first claim wins.
--   unclaim     on unlink. public.api_link_remove also removes the login here.
--
-- Emails: billing.outbox (intent only), sent by notify
--   Producers: triggers on bills, tries, refunds, plans, cards, plants and account
--   events, and billing.outbox_sweep(at) for what only the clock tells.
--   Each kind has a send-time guard tied to its exact bill, try, refund, plan, event or
--   date (outbox_guard); billing.outbox_take re-reads screen_state at send time and drops
--   stale rows. Receipts read the frozen bill. After the switch the old billing,
--   free-week and history emails are no longer queued (email_queue_old_billing).
--
-- Reading: my_plant_ids, live_plants and api_me's plants follow the new state once the
-- switch is on. sync-plant-energy writes through q_upsert_plant_energy_v2 (guarded).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------------

-- The account of a signed-in user, made on first use in the only market.
create function billing.account_of(p_user uuid, p_create boolean default true)
returns uuid language plpgsql set search_path = billing, pg_temp as $$
declare acc uuid; mk text;
begin
  if p_user is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select id into acc from billing.accounts where user_id = p_user;
  if acc is null and p_create then
    mk := (select min(code) from billing.markets having count(*) = 1);
    if mk is null then raise exception 'which market?' using errcode = '22023'; end if;
    insert into billing.accounts (user_id, market) values (p_user, mk) on conflict (user_id) do nothing;
    select id into acc from billing.accounts where user_id = p_user;
  end if;
  return acc;
end $$;

-- The price this account pays for a plan now: a running plan keeps its offer; a new
-- purchase gets the offer it is offered (offer_for), else list.
create function billing.price_shown(p_account uuid, p_plan text, p_interval text, p_at timestamptz)
returns billing.prices language plpgsql stable set search_path = billing, pg_temp as $$
declare
  a billing.accounts;
  s billing.subscriptions;
  pr billing.prices;
  off text;
begin
  select * into a from billing.accounts where id = p_account;
  if (billing.account_status(p_account, p_at)).sub is not null then
    s := billing.live_sub(p_account);
    return billing.price_keeping_offer(p_plan, a.market, p_interval, s.offer, p_at);
  end if;
  off := billing.offer_for(p_account, p_at);
  if off is not null then pr := billing.price_for(p_plan, a.market, p_interval, off, p_at); end if;
  if pr.id is null then pr := billing.price_for(p_plan, a.market, p_interval, null, p_at); end if;
  return pr;
end $$;

-- Would another account keep this plant's history if this account let it go now?
create function billing.kept_elsewhere(p_account uuid, p_plant bigint, p_at timestamptz)
returns boolean language plpgsql stable set search_path = billing, pg_temp as $$
declare se record; st billing.status;
begin
  for se in select s.account from billing.seats s
             where s.plant = p_plant and s.account <> p_account and s.closed_at is null loop
    st := billing.account_status(se.account, p_at);
    if st.state in ('trialing', 'active', 'past_due') then return true; end if;
    if st.state = 'ended' and st.access_ended_at + make_interval(days => st.retention_days) > p_at then return true; end if;
  end loop;
  return false;
end $$;

-- Until when other accounts would keep this plant's history on what is booked now: a plan
-- that renews (or is unpaid but still running) keeps it with no end; a booked cancel, the
-- free week, a grant that ends or an ended plan keeps it for the retention days after its
-- end. A booked downgrade that drops the plant keeps it to the billing date only (the drop
-- deletes it then). Null: no other account holds it.
create function billing.kept_by_others_until(p_account uuid, p_plant bigint, p_at timestamptz)
returns timestamptz language plpgsql stable set search_path = billing, pg_temp as $$
declare se record; st billing.status; latest timestamptz; ends timestamptz;
begin
  for se in select s.account, s.drop_at_period_end from billing.seats s
             where s.plant = p_plant and s.account <> p_account and s.closed_at is null loop
    st := billing.account_status(se.account, p_at);
    ends := case when st.state = 'active' and st.sub is null then
                   -- grants only: the latest end (none: no end)
                   (select case when bool_or(g.ends_at is null) then 'infinity'::timestamptz else max(g.ends_at) end
                      from billing.grants g where g.account = se.account and g.starts_at <= p_at
                       and (g.ends_at is null or g.ends_at > p_at))
                 when st.state = 'past_due' or (st.state = 'active' and st.cancel_at is null) then 'infinity'
                 when st.state = 'active' then st.cancel_at
                 when st.state = 'trialing' then st.trial_ends_at
                 when st.state = 'ended' then st.access_ended_at end;
    if se.drop_at_period_end and st.state in ('active', 'past_due') and st.sub is not null then
      ends := st.period_end;                     -- dropped then, no retention
    elsif ends is not null and ends <> 'infinity' then
      ends := ends + make_interval(days => st.retention_days);
    end if;
    latest := greatest(latest, ends);
  end loop;
  return latest;
end $$;

create function billing.screen_state(p_account uuid, p_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = billing, pg_temp as $$
declare
  s jsonb;
  a billing.accounts;
  m billing.markets;
  sub billing.subscriptions;
  last_sub billing.subscriptions;
  next_places int;
  prices jsonb;
  plants jsonb;
begin
  s := billing.account_state(p_account, p_at);
  if s is null then return null; end if;
  select * into a from billing.accounts where id = p_account;
  select * into m from billing.markets where code = a.market;
  if s->>'state' in ('active', 'past_due') then sub := billing.live_sub(p_account); end if;
  select * into last_sub from billing.subscriptions where account = p_account and started_at <= p_at
   order by started_at desc limit 1;
  if sub.id is not null then
    next_places := coalesce((select pl.places from billing.prices pr join billing.plans pl on pl.code = pr.plan
                              where pr.id = sub.next_price),
                            (select places from billing.plans where code = sub.plan))
                   + coalesce(sub.next_extra_places, sub.extra_places) + billing.grant_places(p_account, p_at);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'plan', pl.code, 'name', pl.name, 'places', pl.places, 'interval', iv.x,
           'amount_minor', pr.amount_minor, 'list_minor', lp.amount_minor, 'offer', pr.offer,
           'currency', m.currency) order by pl.places, iv.x), '[]'::jsonb)
    into prices
    from billing.plans pl cross join (values ('month'), ('year')) iv (x)
    cross join lateral billing.price_shown(p_account, pl.code, iv.x, p_at) pr
    cross join lateral billing.price_for(pl.code, a.market, iv.x, null, p_at) lp
   where pr.id is not null;

  -- each plant: what letting it go would do, and a booked drop
  select coalesce(jsonb_agg(p || jsonb_build_object(
           'kept_elsewhere', billing.kept_elsewhere(p_account, (p->>'plant')::bigint, p_at),
           'drop_at_period_end', coalesce((select se.drop_at_period_end from billing.seats se
                                             where se.account = p_account and se.plant = (p->>'plant')::bigint
                                               and se.closed_at is null), false),
           -- the logins that list it now, and the ones it went from (removing the last route deletes it)
           'logins', coalesce((select jsonb_agg(l.id order by l.created_at) from billing.logins l
                                 join billing.login_plants lp on lp.login = l.id
                                where l.account = p_account and lp.plant = (p->>'plant')::bigint and lp.gone_at is null), '[]'::jsonb),
           'gone_logins', coalesce((select jsonb_agg(l.id order by l.created_at) from billing.logins l
                                      join billing.login_plants lp on lp.login = l.id
                                     where l.account = p_account and lp.plant = (p->>'plant')::bigint and lp.gone_at is not null), '[]'::jsonb),
           'claimed', exists (select 1 from billing.plant_claims c where c.account = p_account and c.plant = (p->>'plant')::bigint),
           -- it came through the share: removing the shared group lets it go (api_link_remove)
           'shared', exists (select 1 from public.plant_users pu join private.sunsynk_accounts sa on sa.id = pu.account_id
                              where sa.kind = 'share' and pu.plant_id = (p->>'plant')::bigint
                                and pu.user_id = a.user_id))
         order by (p->>'plant')::bigint), '[]'::jsonb)
    into plants from jsonb_array_elements(s->'plants') p;

  return s || jsonb_build_object(
    'plants', plants,
    'at', p_at,                                  -- when this was read: dates before it have passed
    'time_zone', coalesce(a.time_zone, m.default_time_zone),
    'locale', a.locale,
    'plan_name', (select name from billing.plans where code = s->>'plan'),
    'next_plan_name', (select name from billing.plans where code = s->>'next_plan'),
    'next_places', next_places,
    'fit_all_name', (select name from billing.plans where code = s->>'fit_all_plan'),
    'last_plan', last_sub.plan,
    'last_plan_name', (select name from billing.plans where code = last_sub.plan),
    'had_plan', last_sub.id is not null,
    -- ended on a plan from us (a grant ended last), not on a paid plan or the free week
    'grant_ended', s->>'state' = 'ended' and exists (select 1 from billing.grants g where g.account = p_account
                      and g.ends_at = (s->>'access_ended_at')::timestamptz),
    'retention_days', m.retention_days,
    'trial_places', m.trial_places,
    -- the free week's last two days; a booked cancel's last three
    'trial_ends_soon', s->>'state' = 'trialing' and (s->>'trial_ends_at')::timestamptz - p_at <= interval '2 days',
    'cancel_soon', (s->>'cancel_at')::timestamptz - p_at <= interval '3 days',
    -- what a cancel (booked now, or already booked) means: this account's deadline, shown when
    -- it is the one that decides for a chosen plant, that is no other account would keep that
    -- plant's history longer on what is booked now. Null: no such plant.
    'if_cancelled_delete_at', case when sub.id is not null
                                    and exists (select 1 from jsonb_array_elements(plants) p
                                                 where (p->>'chosen')::boolean and not (p->>'purged')::boolean
                                                   and coalesce(billing.kept_by_others_until(p_account, (p->>'plant')::bigint, p_at),
                                                                '-infinity') <= sub.period_end + make_interval(days => m.retention_days))
                                   then sub.period_end + make_interval(days => m.retention_days) end,
    -- the earliest "kept until" among the chosen plants (null: nothing waits to be deleted)
    'history_kept_until', (select min((p->>'delete_at')::timestamptz) from jsonb_array_elements(plants) p
                            where (p->>'chosen')::boolean and (p->>'delete_at')::timestamptz > p_at),
    'history_purged', exists (select 1 from jsonb_array_elements(plants) p where (p->>'chosen')::boolean and (p->>'purged')::boolean),
    'prices', prices,
    'logins', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'brand', l.brand, 'username', l.username,
                          'status', l.status) order by l.created_at)
                          from billing.logins l where l.account = p_account), '[]'::jsonb),
    'bills', coalesce((select jsonb_agg(b order by b->>'paid_at' desc) from (
                select jsonb_build_object('id', i.id, 'kind', i.kind, 'plan', i.plan,
                         'plan_name', i.plan_name, 'interval', i.interval,
                         'amount_minor', i.amount_minor, 'currency', i.currency, 'paid_at', i.paid_at,
                         'period_start', i.period_start, 'period_end', i.period_end,
                         'refunded', exists (select 1 from billing.payment_attempts pa join billing.refunds r on r.attempt = pa.id
                                              where pa.invoice = i.id and r.status = 'processed')) b
                  from billing.invoices i
                 where i.account = p_account and i.status = 'paid' and i.kind <> 'card_check' and i.amount_minor > 0
                 order by i.paid_at desc limit 6) x), '[]'::jsonb));
end $$;

-- What a plan change would charge: a first plan or restart (purchase), an upgrade now for
-- the days left (the same count as billing.upgrade), or a booked downgrade or interval.
create function billing.quote(p_account uuid, p_plan text, p_interval text, p_at timestamptz default now())
returns jsonb language plpgsql stable set search_path = billing, pg_temp as $$
declare
  a billing.accounts;
  m billing.markets;
  st billing.status;
  s billing.subscriptions;
  pl billing.plans;
  pr billing.prices;
  cur_places int;
  days_left int;
  days_all int;
  due int;
begin
  select * into a from billing.accounts where id = p_account;
  select * into m from billing.markets where code = a.market;
  st := billing.account_status(p_account, p_at);
  select * into pl from billing.plans where code = p_plan;
  if not found then raise exception 'no such plan' using errcode = '22023'; end if;
  if st.sub is null then
    pr := billing.price_shown(p_account, p_plan, p_interval, p_at);
    return jsonb_build_object('kind', 'purchase', 'plan', p_plan, 'plan_name', pl.name, 'places', pl.places,
      'interval', p_interval, 'due_minor', pr.amount_minor, 'next_amount_minor', pr.amount_minor,
      'next_at', billing.add_period(p_at, p_interval, extract(day from p_at at time zone m.default_time_zone)::int, m.default_time_zone),
      'currency', m.currency, 'offer', pr.offer);
  end if;
  s := billing.live_sub(p_account);
  cur_places := (select places from billing.plans where code = s.plan) + s.extra_places;
  if pl.places > cur_places then
    pr := billing.price_keeping_offer(p_plan, a.market, s.interval, s.offer, p_at);
    days_all := (s.period_end at time zone m.default_time_zone)::date - (s.period_start at time zone m.default_time_zone)::date;
    -- a paid year copied from the old billing starts on its billing date, maybe still ahead
    days_left := least((s.period_end at time zone m.default_time_zone)::date - (p_at at time zone m.default_time_zone)::date, days_all);
    due := greatest(round(((pr.amount_minor) - (s.amount_minor + s.extra_places * s.extra_place_minor))::numeric
                          * days_left / greatest(days_all, 1)), 0)::int;
    return jsonb_build_object('kind', 'upgrade', 'plan', p_plan, 'plan_name', pl.name, 'places', pl.places,
      'interval', s.interval, 'due_minor', case when due < m.min_charge_minor then 0 else due end,
      'next_amount_minor', pr.amount_minor, 'next_at', s.period_end, 'currency', s.currency, 'offer', pr.offer);
  end if;
  pr := billing.price_keeping_offer(p_plan, a.market, coalesce(p_interval, s.interval), s.offer, p_at);
  return jsonb_build_object('kind', case when pl.places < cur_places then 'downgrade' else 'interval' end,
    'plan', p_plan, 'plan_name', pl.name, 'places', pl.places, 'interval', pr.interval, 'due_minor', 0,
    'next_amount_minor', pr.amount_minor, 'next_at', s.period_end, 'currency', s.currency, 'offer', pr.offer,
    'drop', greatest(st.chosen - pl.places - billing.grant_places(p_account, p_at), 0));
end $$;

create function public.api_account_state()
returns jsonb language plpgsql volatile security definer set search_path = billing, pg_temp as $$
begin
  return billing.screen_state(billing.account_of(auth.uid()));
end $$;

create function public.api_choose_plants(p_plants bigint[])
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare acc uuid := billing.account_of(auth.uid());
begin
  perform billing.set_chosen_plants(acc, p_plants);
  return billing.screen_state(acc);
end $$;

create function public.api_plan_quote(p_plan text, p_interval text default null)
returns jsonb language plpgsql stable security definer set search_path = billing, pg_temp as $$
declare acc uuid := billing.account_of(auth.uid(), false);
begin
  if acc is null then raise exception 'sign in first' using errcode = '42501'; end if;
  return billing.quote(acc, p_plan, coalesce(p_interval, 'month'));
end $$;

-- ---------------------------------------------------------------------------
-- Claims: a plant shared to our service login. First claim wins (accepted risk).
-- ---------------------------------------------------------------------------
create function billing.claim_plant(p_account uuid, p_plant bigint, p_name text, p_brand text default 'sunsynk',
                                    p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare st billing.status; holder uuid;
begin
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  insert into billing.plants (id, brand, external_id) values (p_plant, p_brand, p_plant::text) on conflict (id) do nothing;
  perform billing.lock_plants(array[p_plant]);
  select account into holder from billing.plant_claims where plant = p_plant;
  if holder is not null and holder <> p_account then raise exception 'taken' using errcode = '22023'; end if;
  if holder is not null then
    update billing.plant_claims set plant_name = coalesce(p_name, plant_name) where plant = p_plant;
  else
    if st.state = 'ended' and not billing.has_route(p_account, p_plant, false) then
      raise exception 'no plant can be added without a plan' using errcode = '22023';
    end if;
    insert into billing.plant_claims (plant, account, claimed_at, plant_name) values (p_plant, p_account, p_at, p_name);
    update billing.plants set version = version + 1 where id = p_plant;
    update billing.accounts set version = version + 1 where id = p_account;
    perform billing.log_event(p_account, p_at, p_actor, 'claim_plant', jsonb_build_object('state', st.state),
                              jsonb_build_object('plant', p_plant, 'name', p_name));
  end if;
  return billing.account_state(p_account, p_at);
end $$;

-- A share removed or given up: the claim goes; a seat with no other route closes.
create function billing.unclaim(p_account uuid, p_plants bigint[], p_at timestamptz default now(), p_actor text default 'owner')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare closed bigint[];
begin
  perform billing.lock_account(p_account);
  perform billing.lock_plants(p_plants);
  delete from billing.plant_claims where account = p_account and plant = any (p_plants);
  with c as (
    update billing.seats set closed_at = p_at, close_reason = 'login_removed'
     where account = p_account and closed_at is null and plant = any (p_plants)
       and not billing.has_route(p_account, plant, false)
    returning plant)
  select coalesce(array_agg(plant order by plant), '{}') into closed from c;
  update billing.plants set version = version + 1 where id = any (p_plants);
  -- a closed plant nothing keeps is deleted now, under its lock
  perform billing.purge_now(x, p_at) from unnest(closed) x;
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'unclaim', null,
                            jsonb_build_object('plants', to_jsonb(p_plants), 'closed', to_jsonb(closed)));
  return billing.account_state(p_account, p_at);
end $$;

-- The door for link-sunsynk and claim-share (service role only). args.user is the
-- signed-in user. Before the switch these writes keep the new tables filled; after it
-- their refusals are the rules.
create function public.billing_links(p_cmd text, p_args jsonb)
returns jsonb language plpgsql security definer set search_path = billing, private, pg_temp as $$
declare acc uuid := billing.account_of((p_args->>'user')::uuid);
begin
  return case p_cmd
    when 'state' then billing.account_state(acc) || jsonb_build_object('live', billing.is_live(),
                        'login_known', exists (select 1 from billing.logins l where l.account = acc
                                                  and lower(l.username) = lower(p_args->>'username')))
    -- the vault id is the stored login's own (private.sunsynk_accounts)
    when 'link_login' then billing.link_login(acc, coalesce(p_args->>'brand', 'sunsynk'), p_args->>'username',
                             (select sa.refresh_secret_id from private.sunsynk_accounts sa where sa.id = (p_args->>'login')::uuid),
                             p_args->'plants', now(), 'owner', (p_args->>'login')::uuid)
    when 'claim_plant' then billing.claim_plant(acc, (p_args->>'plant')::bigint, p_args->>'name')
    else billing.unknown_command(p_cmd)
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Linking a login. 0203's account_upsert, matched on the email in any case: a reconnect
-- typed in another case updates the stored login, never adds a second one.
-- ---------------------------------------------------------------------------
create or replace function public.account_upsert(p_user uuid, p_username text, p_access text, p_expires bigint)
returns uuid language plpgsql security definer set search_path = private, pg_temp as $$
declare acc uuid;
begin
  -- plant_users_upsert's order (0170), so two links at once queue here and the second sees the first's login
  perform pg_advisory_xact_lock_shared(3, 0);
  perform private.billing_lock(p_user);
  if not public.link_login_allowed(p_user, p_username) then
    raise exception 'one login' using errcode = '22023';
  end if;
  -- the same login whatever the case of its email (SunSynk ignores it): the row already
  -- stored is updated in place; a new one only when there is none
  select id into acc from private.sunsynk_accounts
   where user_id = p_user and kind = 'login' and lower(sunsynk_username) = lower(p_username)
   order by sunsynk_username = p_username desc, id limit 1;
  -- Before the update below wipes status and last_error. A first link has no row.
  insert into private.sunsynk_login_events (account_id, event, reason, last_ok_at, access_expires_at)
  select id, 'relinked', status || coalesce(': ' || last_error, ''), last_ok_at, access_expires_at
    from private.sunsynk_accounts where id = acc;
  if acc is null then
    insert into private.sunsynk_accounts (user_id, sunsynk_username, access_token, access_expires_at, status, last_ok_at, last_error)
    values (p_user, p_username, p_access, p_expires, 'active', now(), null)
    returning id into acc;
  else
    update private.sunsynk_accounts
       set access_token = p_access, access_expires_at = p_expires, status = 'active', last_ok_at = now(), last_error = null
     where id = acc;
  end if;
  -- A fresh sign-in replaces whatever the other copies held. The refresh token
  -- follows in account_refresh_set, which link-sunsynk calls next.
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires, status = 'active', last_error = null
   where id in (select private.login_copies(acc));
  return acc;
end $$;

-- Live billing: the stored login, its refresh token and billing.link_login in one
-- transaction, so a login billing refuses (or a failure on the way) leaves no login row
-- and no vault secret behind.
create function public.link_login_live(p_user uuid, p_username text, p_access text, p_expires bigint,
                                       p_refresh text, p_plants jsonb)
returns uuid language plpgsql security definer set search_path = public, private, pg_temp as $$
declare acc uuid;
begin
  acc := public.account_upsert(p_user, p_username, p_access, p_expires);
  perform public.account_refresh_set(acc, p_refresh);
  perform public.billing_links('link_login', jsonb_build_object('user', p_user, 'login', acc, 'username', p_username,
                                                                 'plants', coalesce(p_plants, '[]'::jsonb)));
  return acc;
end $$;
revoke all on function public.link_login_live(uuid, text, text, bigint, text, jsonb) from public, anon, authenticated;
grant execute on function public.link_login_live(uuid, text, text, bigint, text, jsonb) to service_role;

-- Live billing: a plant shared to our login. billing.claim_plant decides who gets it (first
-- claim wins; an ended account may repair a claim it holds) and the link row is written in
-- the same transaction, so the two never disagree. Another user's own-login row does not
-- block it: that user reads the plant through their own login. Another user's live share
-- claim while billing granted this one: an error, nothing written.
create function public.share_claim_live(p_user uuid, p_account uuid, p_plant bigint, p_plant_name text)
returns text language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  mine public.plant_users;
  lapsed uuid[];
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and kind = 'share' and status <> 'disabled') then
    raise exception 'share_claim: % is not the share login', p_account;
  end if;
  -- account_upsert's order (link_login_live): the run, the user; then plant_users_upsert's:
  -- account, plant; billing's rows after
  perform pg_advisory_xact_lock_shared(3, 0);
  perform private.billing_lock(p_user);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  perform pg_advisory_xact_lock(p_plant);
  -- read already (own login, or a live claim): no claim row without a share route
  select * into mine from public.plant_users where plant_id = p_plant and user_id = p_user;
  if found and (not mine.via_share or mine.share_gone_at is null) then return 'yours'; end if;
  perform public.billing_links('claim_plant', jsonb_build_object('user', p_user, 'plant', p_plant, 'name', p_plant_name));

  if exists (select 1 from public.plant_users o
              where o.plant_id = p_plant and o.user_id <> p_user and o.via_share and o.share_gone_at is null) then
    raise exception 'share_claim: plant % is claimed in plant_users by another user', p_plant;
  end if;
  -- a claim that lapsed when the share was removed gives way to this one
  with d as (delete from public.plant_users
              where plant_id = p_plant and user_id <> p_user and via_share and share_gone_at is not null
             returning user_id)
  select coalesce(array_agg(user_id), '{}') into lapsed from d;
  delete from public.email_queue where plant_id = p_plant and user_id = any (lapsed) and status = 'queued';
  perform public.plant_users_upsert(p_user, p_account,
    jsonb_build_array(jsonb_build_object('plant_id', p_plant, 'plant_name', p_plant_name)));
  update public.plant_users set via_share = true, share_missing_at = null, share_gone_at = null
   where plant_id = p_plant and user_id = p_user;
  return 'claimed';
end $$;
revoke all on function public.share_claim_live(uuid, uuid, bigint, text) from public, anon, authenticated;
grant execute on function public.share_claim_live(uuid, uuid, bigint, text) to service_role;

-- 0172's share_sync, plus: a share removed in the inverter cloud (share_gone_at set) lets
-- go of the billing claim too, so the plant stops being read and someone else can claim it.
-- The seat stays and nothing is deleted: the history is kept while the plan runs ("your
-- history is safe"). Only a login or claim the owner removes deletes at once.
create or replace function public.share_sync(p_account uuid, p_plants bigint[])
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  now_s bigint := extract(epoch from now())::bigint;
  back int; missing int; gone int := 0;
  g record;
  acc uuid;
begin
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (SOLAR-438)
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));

  -- in the list: a miss is forgotten (a stopped claim waits for its owner's Check)
  update public.plant_users pu set share_missing_at = null
   where pu.account_id = p_account and pu.via_share and pu.plant_id = any (p_plants)
     and pu.share_missing_at is not null and pu.share_gone_at is null;
  get diagnostics back = row_count;

  -- not in the list: first miss noted, so one bad list can't stop a plant
  update public.plant_users pu set share_missing_at = now()
   where pu.account_id = p_account and pu.via_share and pu.share_gone_at is null and pu.share_missing_at is null
     and pu.plant_id <> all (p_plants);
  get diagnostics missing = row_count;

  -- still missing an hour on: stop it, release the claim and tell the owner once
  for g in
    update public.plant_users pu set share_gone_at = now()
     where pu.account_id = p_account and pu.via_share and pu.share_gone_at is null
       and pu.share_missing_at < now() - interval '50 minutes' and pu.plant_id <> all (p_plants)
    returning pu.user_id, pu.plant_id, pu.plant_name
  loop
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    values (g.user_id, g.plant_id, 'share_removed', 'share_removed:' || g.plant_id || ':' || now_s,
            jsonb_build_object('plants', jsonb_build_array(coalesce(g.plant_name, 'Plant ' || g.plant_id))), 1)
    on conflict do nothing;
    gone := gone + 1;
    acc := billing.account_of(g.user_id, false);
    if acc is not null and exists (select 1 from billing.plant_claims c where c.account = acc and c.plant = g.plant_id) then
      perform billing.lock_account(acc);
      perform billing.lock_plants(array[g.plant_id]);
      delete from billing.plant_claims where account = acc and plant = g.plant_id;
      update billing.plants set version = version + 1 where id = g.plant_id;
      update billing.accounts set version = version + 1 where id = acc;
      perform billing.log_event(acc, now(), 'share_gone', 'unclaim', null,
                                jsonb_build_object('plants', jsonb_build_array(g.plant_id), 'closed', '[]'::jsonb));
    end if;
  end loop;

  return jsonb_build_object('back', back, 'missing', missing, 'gone', gone);
end $$;

-- The old remove keeps doing its part (vault, plant_users, share release); the new
-- tables lose the login or the claims too.
create or replace function public.api_link_remove(p_account uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  acc uuid := billing.account_of(auth.uid(), false);
  shared bigint[];
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and user_id = auth.uid())
     and not exists (select 1 from private.sunsynk_accounts a where a.id = p_account and a.kind = 'share'
                       and exists (select 1 from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid())) then
    raise exception 'not your account' using errcode = '42501';
  end if;
  shared := array(select x.plant_id from public.plant_users x where x.account_id = p_account and x.user_id = auth.uid());
  if exists (select 1 from private.sunsynk_accounts where id = p_account and kind = 'share') then
    perform private.share_release(p_account, auth.uid());
    if acc is not null and cardinality(shared) > 0 then perform billing.unclaim(acc, shared); end if;
  else
    perform public.api_link_disconnect(p_account);
    if acc is not null and exists (select 1 from billing.logins where id = p_account and account = acc) then
      perform billing.remove_login(acc, p_account);
    end if;
  end if;
  -- plants gone: off the delete lists too
  update private.billing
     set plants_to_remove = array(select x from unnest(plants_to_remove) x
                                   where exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = x)),
         free_removals = array(select x from unnest(free_removals) x
                                where exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = x)),
         updated_at = now()
   where user_id = auth.uid() and cardinality(plants_to_remove) > 0;
  update private.billing set remove_on = null where user_id = auth.uid() and cardinality(plants_to_remove) = 0 and remove_on is not null;
  return jsonb_build_object('result', 'removed');
end $$;

-- The signed-in user's logins and their plants (api_link_status's shape, no old billing):
-- paused = not chosen (no open seat). Plants choose, lock and delete in api_account_state.
create function public.api_logins()
returns table (account_id uuid, sunsynk_username text, status text, linked_at timestamptz, last_ok_at timestamptz,
               plants jsonb, kind text)
language sql stable security definer set search_path = public, private, pg_temp as $$
  with me as (select auth.uid() u, (select id from billing.accounts where user_id = auth.uid()) acc)
  select a.id, a.sunsynk_username, a.status,
         case when a.kind = 'share' then (select min(x.linked_at) from public.plant_users x where x.account_id = a.id and x.user_id = me.u)
              else a.linked_at end,
         a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name,
                     'paused', not exists (select 1 from billing.seats se where se.account = me.acc and se.plant = pu.plant_id
                                              and se.closed_at is null),
                     'linked_at', pu.linked_at,
                     'inverters', (select count(*) from private.inverters i where i.plant_id = pu.plant_id),
                     'share_gone', pu.share_gone_at is not null,
                     'started_at', (select s.started_at from private.plant_alert_state s where s.plant_id = pu.plant_id))
                   order by pu.linked_at, pu.plant_id)
                     from public.plant_users pu where pu.account_id = a.id and pu.user_id = me.u), '[]'::jsonb),
         a.kind
    from private.sunsynk_accounts a cross join me
   where a.user_id = me.u
      or (a.kind = 'share' and exists (select 1 from public.plant_users x where x.account_id = a.id and x.user_id = me.u))
   order by 4 desc
$$;
revoke all on function public.api_logins() from public, anon;
grant execute on function public.api_logins() to authenticated;

-- The plants a user's account reads (chosen), for the edge functions (syncPlants, notify):
-- open seats once the switch is on, before it the old rule (not paused). The drop migration
-- keeps the first half only, so no function outside the database reads plant_users.paused.
create function public.chosen_plant_ids(p_user uuid)
returns bigint[] language sql stable security definer set search_path = public, private, pg_temp as $$
  select case when billing.is_live()
    then array(select se.plant from billing.seats se join billing.accounts a on a.id = se.account
                where a.user_id = p_user and se.closed_at is null
                  and billing.has_route(a.id, se.plant, false) order by se.plant)
    else array(select pu.plant_id from public.plant_users pu where pu.user_id = p_user and not pu.paused
                order by pu.plant_id) end
$$;
revoke all on function public.chosen_plant_ids(uuid) from public, anon, authenticated;
grant execute on function public.chosen_plant_ids(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Reading follows the new state once the switch is on.
-- ---------------------------------------------------------------------------
-- The plants a signed-in user may see: chosen and not yet deleted (the old rule: not
-- paused, and read or kept).
create or replace function public.my_plant_ids()
returns setof bigint language sql stable security definer set search_path = public, private, pg_temp as $$
  select pu.plant_id
    from public.plant_users pu
   where not billing.is_live() and pu.user_id = auth.uid() and not pu.paused
     and (private.plant_live(pu.user_id, pu.plant_id)
          or exists (select 1 from private.billing b
                      where b.user_id = pu.user_id and b.keep_until >= private.billing_today()))
  union
  select se.plant from billing.seats se join billing.accounts a on a.id = se.account
    join billing.plants p on p.id = se.plant
   where billing.is_live() and a.user_id = auth.uid() and se.closed_at is null and p.history_purged_at is null
     -- a share removed or a plant gone from the login: hidden; its history stays and shows again
     and billing.has_route(a.id, se.plant, false)
$$;

create or replace function public.live_plants()
returns setof bigint language sql stable security definer set search_path = public, private, pg_temp as $$
  select distinct pu.plant_id
    from public.plant_users pu
   where not billing.is_live() and not pu.paused and pu.share_gone_at is null
     and private.plant_live(pu.user_id, pu.plant_id)
  union
  select distinct r.plant from billing.reading_routes(now()) r where billing.is_live()
$$;

-- The old rules that still run after the switch read the frozen old tables. Each one keeps
-- its old body under a new name for before the switch and follows the new state after it.
-- The drop migration (supabase/after-switch-over) removes the old halves.
alter function private.plant_live(uuid, bigint) rename to plant_live_old;
create function private.plant_live(p_user uuid, p_plant bigint)
returns boolean language sql stable set search_path = public, private, pg_temp as $$
  select case when billing.is_live()
              then coalesce(billing.reads_plant((select id from billing.accounts where user_id = p_user), p_plant, now()), false)
              else private.plant_live_old(p_user, p_plant) end
$$;

alter function private.pick_waiting(uuid) rename to pick_waiting_old;
create function private.pick_waiting(p_user uuid)
returns boolean language sql stable set search_path = public, private, pg_temp as $$
  select case when billing.is_live()
              then coalesce((select st.state = 'none' and st.linked > 0 and st.chosen = 0
                               from billing.accounts a cross join lateral billing.account_status(a.id, now()) st
                              where a.user_id = p_user), false)
              else private.pick_waiting_old(p_user) end
$$;

alter function public.link_login_allowed(uuid, text) rename to link_login_allowed_old;
create function public.link_login_allowed(p_user uuid, p_username text)
returns boolean language sql stable security definer set search_path = public, private, pg_temp as $$
  select case when billing.is_live()
              then coalesce((select (billing.account_state(a.id)->>'may_add_login')::boolean
                                    or exists (select 1 from billing.logins l where l.account = a.id and lower(l.username) = lower(p_username))
                               from billing.accounts a where a.user_id = p_user), true)
              else public.link_login_allowed_old(p_user, p_username) end
$$;
revoke all on function public.link_login_allowed_old(uuid, text) from public, anon, authenticated;
revoke all on function public.link_login_allowed(uuid, text) from public, anon, authenticated;
grant execute on function public.link_login_allowed(uuid, text) to service_role;

-- A report still goes: a plan or the week running, and its plant (if any) chosen and still
-- reached (not gone from its login, share not removed; its history stays). Asked when the
-- report is queued (email_skip_unchosen) and again when it is sent (email_claim).
create function billing.report_wanted(p_account uuid, p_plant bigint)
returns boolean language sql stable security definer set search_path = billing, pg_temp as $$
  select coalesce((billing.account_status(p_account, now())).state, 'none') in ('trialing', 'active', 'past_due')
     and (p_plant is null
          or (exists (select 1 from billing.seats s where s.account = p_account and s.plant = p_plant and s.closed_at is null)
              and billing.has_route(p_account, p_plant, false)))
$$;
revoke all on function billing.report_wanted(uuid, bigint) from public, anon, authenticated;

-- Emails for a plant the account does not choose, and reports with no plan, are not queued.
create function private.email_skip_unchosen()
returns trigger language plpgsql security definer set search_path = '' as $$
declare acc uuid;
begin
  if not billing.is_live() then
    -- before the switch: 0222's rule, as it was
    if new.plant_id is not null and exists (select 1 from public.plant_users pu
         where pu.user_id = new.user_id and pu.plant_id = new.plant_id and pu.paused) then
      return null;
    end if;
    if new.kind like 'report\_%' and not coalesce((new.data->>'freeWeekEnds')::boolean, false)
       and coalesce((select b.plan from private.billing b where b.user_id = new.user_id), 'free') = 'free' then
      return null;
    end if;
    if new.plant_id is not null and new.user_id is not null
       and (private.is_alert(new.kind) or new.kind in ('share_down', 'share_back'))
       and not private.plant_live(new.user_id, new.plant_id) then
      return null;
    end if;
    return new;
  end if;
  if new.user_id is null then return new; end if;
  select id into acc from billing.accounts where user_id = new.user_id;
  if new.plant_id is not null and not exists (select 1 from billing.seats s where s.account = acc and s.plant = new.plant_id
                                                 and s.closed_at is null) then
    return null;
  end if;
  if new.kind like 'report\_%' and not billing.report_wanted(acc, new.plant_id) then return null; end if;
  if new.plant_id is not null and (private.is_alert(new.kind) or new.kind in ('share_down', 'share_back'))
     and not private.plant_live(new.user_id, new.plant_id) then
    return null;
  end if;
  return new;
end $$;
revoke all on function private.email_skip_unchosen() from public, anon, authenticated;
drop trigger if exists email_skip_paused on public.email_queue;
create trigger email_skip_paused before insert on public.email_queue
  for each row execute function private.email_skip_unchosen();

-- The sender's batch (email_claim): 0217's body, and after the switch a queued report is
-- checked again (billing.report_wanted): the plan may have ended, the plant been let go or
-- its share removed since it was queued.
create or replace function public.email_claim(p_limit int, p_peek boolean default false)
returns table (id bigint, user_id uuid, to_email text, plant_id bigint, plant_name text, tz text,
               kind text, key text, data jsonb, tries int, switch text, unsub_token uuid, batch_key text)
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if not p_peek then
    -- A sender that died mid-batch: its claims go back on the queue.
    update public.email_queue q set status = 'queued', claimed_at = null
     where q.status = 'sending' and q.claimed_at < now() - interval '10 minutes';
  end if;

  create temp table if not exists _claim (id bigint primary key, skip text, sw text) on commit drop;
  truncate _claim;
  insert into _claim (id, skip, sw)
  select q.id,
         case
           when sw is not null and q.user_id is not null and not public.email_wanted(q.user_id, sw) then 'switched off'
           when q.plant_id is not null and q.user_id is not null and q.kind <> 'needs_relink'
                and not exists (select 1 from public.plant_users pu where pu.user_id = q.user_id and pu.plant_id = q.plant_id)
             then 'plant removed'
           when q.kind = 'history' and q.user_id is not null and q.plant_id is not null
                and not private.plant_live(q.user_id, q.plant_id)
             then 'not read'
           -- after the switch a report is asked again when sent: plan, chosen plant, still reached
           when q.kind like 'report\_%' and q.user_id is not null and billing.is_live()
                and not billing.report_wanted((select ba.id from billing.accounts ba where ba.user_id = q.user_id), q.plant_id)
             then 'report not wanted'
           when q.kind = 'welcome' and exists (select 1 from public.plant_users pu where pu.user_id = q.user_id)
             then 'plant linked'
           when q.kind = 'need_a_hand' and exists (select 1 from private.sunsynk_accounts a where a.user_id = q.user_id)
                and not private.pick_waiting(q.user_id)
             then 'login added'
           when q.pair_key is not null and not exists (
                  select 1 from public.email_queue d where d.user_id is not distinct from q.user_id and d.key = q.pair_key
                     and d.status in ('sent', 'sending', 'queued'))
             then 'down not sent'
         end,
         sw
    from (select q0.*, private.email_switch_of(q0.kind, q0.data) as sw
            from public.email_queue q0
           where q0.status = 'queued' and q0.due_at <= now()
             -- a "back" waits while its "down" is still on its way
             and not exists (select 1 from public.email_queue d
                              where q0.pair_key is not null and d.user_id is not distinct from q0.user_id and d.key = q0.pair_key
                                and (d.status = 'sending' or (d.status = 'queued' and d.due_at > now())))
           order by q0.priority, q0.due_at, q0.id
           limit p_limit
           for update skip locked) q;

  if not p_peek then
    update public.email_queue q set status = 'skipped', last_error = c.skip
      from _claim c where c.id = q.id and c.skip is not null;
    update public.email_queue q set status = 'sending', claimed_at = now(), tries = q.tries + 1
      from _claim c where c.id = q.id and c.skip is null;
  end if;

  return query
  select q.id, q.user_id, coalesce(q.to_email, u.email::text), q.plant_id,
         coalesce(pu.plant_name, (select pu2.plant_name from public.plant_users pu2
                                   where pu2.user_id = q.user_id order by pu2.linked_at limit 1)),
         case when q.plant_id is not null then public.plant_tz(q.plant_id) else 'Africa/Johannesburg' end,
         q.kind, q.key,
         case when q.kind = 'need_a_hand' and exists (select 1 from private.sunsynk_accounts a where a.user_id = q.user_id)
                then coalesce(q.data, '{}'::jsonb) || '{"choose": true}'::jsonb
              else q.data end,
         q.tries, c.sw,
         case when c.sw is not null and q.user_id is not null and not p_peek
              then public.email_unsub_token(q.user_id) end,
         q.batch_key
    from _claim c
    join public.email_queue q on q.id = c.id
    left join auth.users u on u.id = q.user_id
    left join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
   where c.skip is null
   order by q.priority, q.due_at, q.id;
end $$;

-- Account delete after the switch: the new rules decide (billing.delete_account: nothing
-- running, nothing owed, no open dispute), then the logins, links and person go as before.
-- Plants no account protects any more are deleted.
alter function public.api_account_delete() rename to api_account_delete_old;
revoke all on function public.api_account_delete_old() from public, anon, authenticated;
create function public.api_account_delete()
returns jsonb language plpgsql security definer set search_path = public, private, vault, pg_temp as $$
declare
  uid uuid := auth.uid();
  acc record;
  gone jsonb;
  orphans bigint[];
begin
  if not billing.is_live() then return public.api_account_delete_old(); end if;
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  gone := case when exists (select 1 from billing.accounts where user_id = uid)
               then billing.delete_account((select id from billing.accounts where user_id = uid))
               else jsonb_build_object('unprotected', '[]'::jsonb) end;
  orphans := array(select (x)::bigint from jsonb_array_elements_text(gone->'unprotected') x);
  for acc in select id, refresh_secret_id from private.sunsynk_accounts where user_id = uid order by id loop
    perform pg_advisory_xact_lock(1, hashtext(acc.id::text));
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
  return jsonb_build_object('deleted', true, 'plantsRemoved', coalesce(cardinality(orphans), 0));
end $$;
revoke all on function public.api_account_delete() from public, anon;
grant execute on function public.api_account_delete() to authenticated;

-- The old plant wipe (0050, 0150) stands down after the switch: it wipes a plant once no
-- plant_users row is left, which knows nothing of another account's seat, retention or a
-- pending payment. switch_on stops its cron job ('plant-purge'); share release, unlink,
-- account delete and a relink still call these, so they do nothing once live. Every
-- delete after the switch is billing.purge_now / billing.delete_due.
create or replace function private.plants_tombstone(p_plants bigint[])
returns void language plpgsql set search_path = public, private, pg_temp as $$
begin
  if billing.is_live() then return; end if;
  insert into private.plant_purge (plant_id)
  select distinct p from unnest(p_plants) p
  on conflict (plant_id) do nothing;
  delete from public.app_config
   where key = 'CALIBRATION_PLANT' and value = any (p_plants::double precision[]);
end $$;

-- 0150's body, with the switch check first.
create or replace function private.purge_plant(p_plant bigint, p_wait boolean default true)
returns jsonb language plpgsql set search_path = public, private, pg_temp as $$
declare
  out jsonb;
  n bigint;
begin
  if billing.is_live() then return null; end if;
  if p_wait then
    perform pg_advisory_xact_lock(p_plant);
  elsif not pg_try_advisory_xact_lock(p_plant) then
    return null;
  end if;
  if not exists (select 1 from private.plant_purge where plant_id = p_plant) then
    return null;
  end if;
  if exists (select 1 from public.plant_users where plant_id = p_plant) then
    delete from private.plant_purge where plant_id = p_plant;
    return jsonb_build_object('skipped', 'linked again');
  end if;

  out := private.plant_readings_delete(p_plant);
  delete from public.plant_config          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from public.config_changes        where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('config_changes', n);
  delete from private.meta                 where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  delete from private.plant_alert_state    where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_alert_state', n);
  delete from private.inverter_alert_state where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_alert_state', n);
  delete from private.string_alert_state   where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('string_alert_state', n);
  delete from private.plant_wipe           where plant_id = p_plant;
  delete from private.plant_purge          where plant_id = p_plant;
  return out;
end $$;

-- The other old jobs that delete or change readings, plants or links stand down after the
-- switch too (their cron jobs are off from switch_on; anything still calling them gets
-- nothing done). 0260 drops them.
--   plant_wipe_readings (0150)  a stop's wipe (plant-wipe job, a restart or swap queues it)
--   unpaid_delete (0217)        day-37 delete of an unpaid plant (unpaid-delete job)
--   billing_drop_plant (0116)   the old run's downgrade and cancel drops: unlinks the plant
--                               and removes a login left with no plant
create or replace function private.plant_wipe_readings(p_plant bigint)
returns bigint
language plpgsql
set search_path = public, private, pg_temp
as $$
declare total bigint;
begin
  if billing.is_live() then return 0; end if;
  perform pg_advisory_xact_lock(p_plant);
  -- Started again while it waited: keep everything.
  if exists (select 1 from public.plant_users where plant_id = p_plant and not paused) then
    delete from private.plant_wipe where plant_id = p_plant;
    return 0;
  end if;
  select coalesce(sum(v::bigint), 0) into total from jsonb_each_text(private.plant_readings_delete(p_plant)) as t(k, v);
  update public.plant_config
     set backfill_next = null, backfill_until = null, backfill_tries = 0, temp_next = null
   where plant_id = p_plant;
  delete from private.plant_wipe where plant_id = p_plant;
  return total;
end $$;

-- 0217's body, with the switch check first.
create or replace function private.unpaid_delete()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $$
declare
  p bigint;
  plants int := 0;
  total bigint := 0;
begin
  if billing.is_live() then return jsonb_build_object('live', true); end if;
  for p in
    select pu.plant_id
      from public.plant_users pu
      left join private.billing b on b.user_id = pu.user_id
     where not pu.paused
     group by pu.plant_id
    having bool_and(not private.plant_live(pu.user_id, pu.plant_id)
                    and private.unpaid_since(pu.user_id) + interval '30 days' <= now()
                    and (b.keep_until is null or b.keep_until < private.billing_today()))
     order by pu.plant_id
  loop
    perform pg_advisory_xact_lock(p);
    -- a payment or a link that landed while this run waited for the lock
    continue when exists (select 1 from public.plant_users pu
                           where pu.plant_id = p and not pu.paused
                             and (private.plant_live(pu.user_id, p)
                                  or private.unpaid_since(pu.user_id) + interval '30 days' > now()));
    continue when not (exists (select 1 from public.agg_minute where plant_id = p)
                    or exists (select 1 from public.agg_5m where plant_id = p)
                    or exists (select 1 from public.readings where plant_id = p)
                    or exists (select 1 from public.plant_energy where plant_id = p)
                    or exists (select 1 from public.grid_off where plant_id = p));
    plants := plants + 1;
    total := total + (select coalesce(sum(v::bigint), 0) from jsonb_each_text(private.plant_readings_delete(p)) as t(k, v));
    update public.plant_config
       set backfill_next = null, backfill_until = null, backfill_tries = 0, temp_next = null
     where plant_id = p;
    -- the day-37 email, to each account with no plan that runs the plant: once per lapse
    insert into public.email_queue (user_id, kind, key, data, priority)
    select pu.user_id, 'unpaid_deleted', 'unpaid_deleted:' || pu.user_id || ':' || private.unpaid_since(pu.user_id)::date,
           jsonb_build_object('plants', (select count(*) from private.plant_picks k where k.user_id = pu.user_id),
             'paid', private.had_plan(pu.user_id)), 1
      from public.plant_users pu
     where pu.plant_id = p and not pu.paused and private.unpaid_since(pu.user_id) is not null
       and not private.no_week(pu.user_id)
       -- only after its 'deleted in 3 days' email was queued: none comes without the warning
       and exists (select 1 from public.email_queue e
                    where e.user_id = pu.user_id and e.kind = 'unpaid_last'
                      and e.created_at >= private.unpaid_since(pu.user_id))
    on conflict do nothing;
  end loop;
  return jsonb_build_object('plants', plants, 'rows', total);
end $$;

-- 0116's body, with the switch check first.
create or replace function private.billing_drop_plant(p_user uuid, p_plant bigint)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'vault', 'pg_temp'
AS $$
declare acc uuid; sid uuid;
begin
  if billing.is_live() then return; end if;
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

-- plant_energy for one plant, written only while it is still read (the poll check).
create function public.q_upsert_plant_energy_v2(p_plant bigint, p_version bigint, p_rows jsonb, p_at timestamptz default now())
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare n integer;
begin
  perform billing.guard_write(p_plant, p_version, p_at);
  perform set_config('billing.guarded', 'on', true);       -- checked above: plant_row_guard lets it through
  insert into public.plant_energy (plant_id, bucket, period, pv_kwh, load_kwh, imp_kwh, exp_kwh, chg_kwh, dischg_kwh, synced_at)
  select p_plant, r.bucket, r.period, r.pv_kwh, r.load_kwh, r.imp_kwh, r.exp_kwh, r.chg_kwh, r.dischg_kwh, r.synced_at
    from jsonb_to_recordset(p_rows) r (bucket text, period date, pv_kwh numeric, load_kwh numeric, imp_kwh numeric,
                                       exp_kwh numeric, chg_kwh numeric, dischg_kwh numeric, synced_at timestamptz)
  on conflict (plant_id, bucket, period) do update
     set pv_kwh = excluded.pv_kwh, load_kwh = excluded.load_kwh, imp_kwh = excluded.imp_kwh, exp_kwh = excluded.exp_kwh,
         chg_kwh = excluded.chg_kwh, dischg_kwh = excluded.dischg_kwh, synced_at = excluded.synced_at;
  get diagnostics n = row_count;
  perform set_config('billing.guarded', 'off', true);
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Emails: billing.outbox
-- ---------------------------------------------------------------------------
alter table billing.outbox add column ref text;               -- the try, refund, plan, event or plant it is about
alter table billing.outbox add column claimed_until timestamptz;
alter table billing.outbox add column tries int not null default 0;
alter table billing.outbox add column drop_reason text;
alter table billing.outbox add column last_error text;
alter table billing.outbox drop constraint outbox_status_check;
alter table billing.outbox add constraint outbox_status_check check (status in ('queued', 'sent', 'dropped', 'failed'));
create index outbox_due on billing.outbox (not_before) where status = 'queued';

-- Every kind, and whether it sits behind the owner's "Offers and reminders" switch.
create table billing.outbox_kinds (
  key      text primary key,
  reminder boolean not null default false
);
insert into billing.outbox_kinds (key, reminder) values
  ('receipt', false), ('payment_failed', false), ('card_update', false), ('refund', false),
  ('plan_ended', false), ('change_booked', false), ('change_undone', false), ('card_changed', false),
  ('renewal_soon', false), ('card_expiring', false),
  ('trial_ends_soon', true), ('trial_ended', true), ('history_delete_soon', true), ('history_deleted', true);
alter table billing.outbox add constraint outbox_key_known foreign key (key) references billing.outbox_kinds (key);

create function billing.outbox_put(p_account uuid, p_key text, p_invoice uuid, p_ref text, p_dedupe text,
                                   p_not_before timestamptz, p_expires timestamptz, p_at timestamptz)
returns void language sql set search_path = billing, pg_temp as $$
  insert into billing.outbox (account, key, invoice, ref, dedupe_key, not_before, expires_at, created_at)
  select p_account, p_key, p_invoice, p_ref, p_dedupe, p_not_before, p_expires, p_at where p_account is not null
  on conflict (dedupe_key) do nothing
$$;

-- A bill paid: its receipt.
create function billing.outbox_on_invoice()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
begin
  if new.status = 'paid' and old.status is distinct from 'paid' and new.kind in ('purchase', 'renewal', 'upgrade')
     and new.amount_minor > 0 then
    perform billing.outbox_put(new.account, 'receipt', new.id, null, 'receipt:' || new.id, new.paid_at, null, new.paid_at);
  end if;
  return null;
end $$;
create trigger invoices_outbox after update of status on billing.invoices
  for each row execute function billing.outbox_on_invoice();

-- A renewal try failed (not the copy's tries, 'copied: ...'): the failed-card email. A hard decline
-- has its card_update email instead (queued by apply_payment).
create function billing.outbox_on_attempt()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
declare inv billing.invoices;
begin
  if new.status = 'failed' and (tg_op = 'INSERT' or old.status is distinct from 'failed')
     and coalesce(new.gateway_response, '') not like 'copied: %' and not new.hard_decline then
    select * into inv from billing.invoices where id = new.invoice;
    if inv.kind = 'renewal' then
      perform billing.outbox_put(inv.account, 'payment_failed', inv.id, new.id::text, 'payment_failed:' || new.id,
                                 coalesce(new.settled_at, new.created_at), null, coalesce(new.settled_at, new.created_at));
    end if;
  end if;
  return null;
end $$;
create trigger payment_attempts_outbox after insert or update of status on billing.payment_attempts
  for each row execute function billing.outbox_on_attempt();

-- Money sent back that the owner did not ask for (stale, duplicate, wrong amount) or a
-- hand refund. Not the card check, not a reversal (the bank told them).
create function billing.outbox_on_refund()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
begin
  if new.status = 'processed' and (tg_op = 'INSERT' or old.status is distinct from 'processed')
     and new.reason not in ('card_check', 'reversed', 'unknown_account') then
    perform billing.outbox_put(new.account, 'refund', null, new.id::text, 'refund:' || new.id, new.updated_at, null, new.updated_at);
  end if;
  return null;
end $$;
create trigger refunds_outbox after insert or update of status on billing.refunds
  for each row execute function billing.outbox_on_refund();

create function billing.outbox_on_sub()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
begin
  if new.status = 'ended' and old.status is distinct from 'ended' then
    perform billing.outbox_put(new.account, 'plan_ended', null, new.id::text, 'plan_ended:' || new.id,
                               greatest(new.ended_at, now()), null, now());
  end if;
  return null;
end $$;
create trigger subscriptions_outbox after update of status on billing.subscriptions
  for each row execute function billing.outbox_on_sub();

-- A new card on an account that had one: card changed. Timed and keyed by the activation, so
-- an old card made active again gets its own email, on time.
create function billing.outbox_on_card()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
declare at timestamptz := coalesce(new.activated_at, new.created_at);
begin
  if new.active and (tg_op = 'INSERT' or not old.active) and new.account is not null
     and exists (select 1 from billing.payment_methods pm where pm.account = new.account and pm.id <> new.id) then
    perform billing.outbox_put(new.account, 'card_changed', null, new.id::text,
                               'card_changed:' || new.id || ':' || extract(epoch from at)::bigint,
                               at, at + interval '2 days', at);
  end if;
  return null;
end $$;
create trigger payment_methods_outbox after insert or update of active on billing.payment_methods
  for each row execute function billing.outbox_on_card();

-- An owner's booked change or its undo. Sent 2 minutes later, so a quick change of mind
-- sends only the last one (the guard drops any but the latest).
create function billing.outbox_on_event()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
begin
  -- (an interval switch that changes nothing logs no event: switch_interval returns first)
  if new.actor = 'owner' and new.kind in ('cancel', 'undo_cancel', 'downgrade', 'switch_interval') then
    perform billing.outbox_put(new.account,
      case when new.kind = 'undo_cancel'
             or (new.kind = 'downgrade' and new.after->>'plan' = new.before->>'plan'
                 and new.after->>'extras' = new.before->>'extras')
             -- back to the interval it has, a switch booked before: the switch is undone
             or (new.kind = 'switch_interval' and new.after->>'interval' = new.before->>'interval'
                 and new.after ? 'next_price' and new.after->>'next_price' is null
                 and new.before->>'next_price' is not null) then 'change_undone' else 'change_booked' end,
      null, new.id::text, 'event:' || new.id, new.at + interval '2 minutes', new.at + interval '2 days', new.at);
  end if;
  return null;
end $$;
create trigger account_events_outbox after insert on billing.account_events
  for each row execute function billing.outbox_on_event();

-- History deleted: each ended account that still held the plant hears once.
create function billing.outbox_on_purge()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
declare se record;
begin
  if new.history_purged_at is not null and old.history_purged_at is null then
    for se in select s.account from billing.seats s where s.plant = new.id and s.closed_at is null loop
      perform billing.outbox_put(se.account, 'history_deleted', null, new.id::text,
                                 'history_deleted:' || se.account || ':' || new.id || ':' || extract(epoch from new.history_purged_at)::bigint,
                                 new.history_purged_at, new.history_purged_at + interval '2 days', new.history_purged_at);
    end loop;
  end if;
  return null;
end $$;
create trigger plants_outbox after update of history_purged_at on billing.plants
  for each row execute function billing.outbox_on_purge();

-- What only the clock tells, once each (dedupe keys carry the date they are about).
--   trial_ends_soon      2 days before the free week ends
--   trial_ended          the free week ended with no plan
--   history_delete_soon  14 and 27 days after the week or plan ended, while history waits
--   renewal_soon         7 days before a yearly plan renews
--   card_expiring        the saved card runs out before the next charge, 30 days ahead
create function billing.outbox_sweep(p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  a record;
  st billing.status;
  s jsonb;
  n int := 0;
  kept timestamptz;
  d int;
begin
  if not billing.is_live() then return jsonb_build_object('live', false); end if;
  for a in select id from billing.accounts loop
    st := billing.account_status(a.id, p_at);
    if st.state = 'trialing' and st.trial_ends_at - p_at <= interval '2 days' then
      perform billing.outbox_put(a.id, 'trial_ends_soon', null, extract(epoch from st.trial_ends_at)::bigint::text,
        'trial_ends_soon:' || a.id || ':' || extract(epoch from st.trial_ends_at)::bigint, p_at, st.trial_ends_at, p_at);
    elsif st.state = 'ended' and st.access_ended_at is not null then
      if st.access_ended_at = st.trial_ends_at and p_at < st.trial_ends_at + interval '2 days'
         and not exists (select 1 from billing.subscriptions x where x.account = a.id) then
        perform billing.outbox_put(a.id, 'trial_ended', null, extract(epoch from st.trial_ends_at)::bigint::text,
          'trial_ended:' || a.id || ':' || extract(epoch from st.trial_ends_at)::bigint, p_at, p_at + interval '2 days', p_at);
      end if;
      foreach d in array array[14, 27] loop
        if p_at >= st.access_ended_at + make_interval(days => d) and p_at < st.access_ended_at + make_interval(days => d + 2) then
          s := billing.account_state(a.id, p_at);
          kept := (select min((p->>'delete_at')::timestamptz) from jsonb_array_elements(s->'plants') p
                    where (p->>'chosen')::boolean and (p->>'delete_at')::timestamptz > p_at);
          if kept is not null then
            perform billing.outbox_put(a.id, 'history_delete_soon', null, extract(epoch from kept)::bigint::text,
              'history_delete_soon:' || d || ':' || a.id || ':' || extract(epoch from st.access_ended_at)::bigint,
              p_at, kept, p_at);
          end if;
        end if;
      end loop;
    elsif st.state = 'active' and st.sub is not null and st.cancel_at is null then
      if st.interval = 'year' and st.period_end - p_at <= interval '7 days' and st.period_end > p_at then
        perform billing.outbox_put(a.id, 'renewal_soon', null, st.sub::text,
          'renewal_soon:' || st.sub || ':' || extract(epoch from st.period_end)::bigint, p_at, st.period_end, p_at);
      end if;
      if st.period_end - p_at <= interval '30 days' and (billing.money_state(a.id, p_at, st.state)->>'card_expires_first')::boolean then
        perform billing.outbox_put(a.id, 'card_expiring', null, (billing.active_method(a.id)).id::text,
          'card_expiring:' || (billing.active_method(a.id)).id || ':' || extract(epoch from st.period_end)::bigint,
          p_at, st.period_end, p_at);
      end if;
    end if;
  end loop;
  select count(*) into n from billing.outbox where status = 'queued';
  return jsonb_build_object('queued', n);
end $$;

-- The send-time guard: null to send, else why the row is dropped. Each kind checks the
-- exact bill, try, refund, plan, event, card or date it was queued for, against the state now.
create function billing.outbox_guard(o billing.outbox, p_at timestamptz)
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
      -- a later try on the same bill has its own email
      if exists (select 1 from billing.payment_attempts pa where pa.invoice = inv.id and pa.status = 'failed'
                    and pa.created_at > (select created_at from billing.payment_attempts where id = o.ref::uuid)) then
        return 'a later try';
      end if;
    when 'card_update' then
      if inv.status is distinct from 'open' then return 'bill settled'; end if;
      if (billing.active_method(o.account)).id is not null then return 'card replaced'; end if;
      if st.state <> 'past_due' then return 'not past due'; end if;
    when 'refund' then
      if not exists (select 1 from billing.refunds r where r.id = o.ref::uuid and r.status = 'processed') then
        return 'refund not processed';
      end if;
    when 'plan_ended' then
      if st.state <> 'ended' then return 'plan running again'; end if;
      if (select s.id from billing.subscriptions s where s.account = o.account order by started_at desc limit 1)
         is distinct from o.ref::uuid then return 'a later plan'; end if;
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

-- notify: the rows due, each with what its email needs, read now. Stale ones are
-- dropped here. A row is leased for 5 minutes while it is sent. Nothing before the switch.
create function billing.outbox_take(p_limit int default 50, p_at timestamptz default now())
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
      if att.payment_method is not null then select * into pm from billing.payment_methods where id = att.payment_method; end if;
    end if;
    update billing.outbox set claimed_until = p_at + interval '5 minutes', tries = tries + 1 where id = o.id;
    out := out || jsonb_build_array(jsonb_build_object(
      'id', o.id, 'key', o.key, 'user', u.id, 'email', u.email, 'unsub_token', u.unsub_token,
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
      'event', (select jsonb_build_object('kind', e.kind, 'before', e.before, 'after', e.after)
                  from billing.account_events e where o.key in ('change_booked', 'change_undone') and e.id = o.ref::bigint),
      'plant', (select jsonb_build_object('id', p.id, 'name', coalesce((select lp.plant_name from billing.login_plants lp
                         join billing.logins l on l.id = lp.login where l.account = o.account and lp.plant = p.id limit 1),
                         (select pu.plant_name from public.plant_users pu where pu.plant_id = p.id and pu.user_id = u.id limit 1)))
                  from billing.plants p where o.key = 'history_deleted' and p.id = o.ref::bigint)));
  end loop;
  return out;
end $$;

-- After a send: sent; failed with a retry (retry_s) or given up (no retry_s after 5 tries).
create function billing.outbox_done(p_id bigint, p_ok boolean, p_error text default null, p_retry_s int default null,
                                    p_at timestamptz default now())
returns void language sql security definer set search_path = billing, pg_temp as $$
  update billing.outbox
     set status = case when p_ok then 'sent' when p_retry_s is null or tries >= 5 then 'failed' else 'queued' end,
         sent_at = case when p_ok then p_at end,
         not_before = case when not p_ok and p_retry_s is not null then p_at + make_interval(secs => p_retry_s) else not_before end,
         last_error = p_error, claimed_until = null
   where id = p_id
$$;

-- After the switch, the old producers' billing, free-week and history emails are not
-- queued any more: the outbox above sends their replacements. The day-7 report goes
-- out as a plain report.
create or replace function private.email_queue_old_billing()
returns trigger language plpgsql set search_path = private, public, pg_temp as $$
begin
  if not billing.is_live() then return new; end if;
  if new.kind in ('free_week_soon', 'unpaid_reminder', 'unpaid_last', 'unpaid_deleted', 'bill_paid', 'bill_upgraded',
                  'bill_switched', 'bill_change', 'bill_kept', 'bill_failed', 'bill_refund', 'bill_free',
                  'bill_removal_soon', 'bill_renewal_notice', 'bill_offer_ends', 'bill_card_changed',
                  'bill_card_expiring', 'winback', 'bill_cancel_soon') then
    return null;
  end if;
  if new.kind like 'report\_%' and new.data ? 'freeWeekEnds' then new.data := new.data - 'freeWeekEnds'; end if;
  return new;
end $$;
drop trigger if exists email_queue_old_billing on public.email_queue;
create trigger email_queue_old_billing before insert on public.email_queue
  for each row execute function private.email_queue_old_billing();

-- notify's door (service role only).
create or replace function public.billing_jobs(p_cmd text, p_args jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
begin
  return case p_cmd
    when 'history_take' then billing.history_take()
    when 'history_step' then billing.history_step((p_args->>'id')::bigint, (p_args->>'day')::date,
                               coalesce((p_args->>'failed')::boolean, false), coalesce((p_args->>'throttled')::boolean, false),
                               now(), (p_args->>'claim')::uuid)
    when 'history_renew' then to_jsonb(coalesce(billing.history_renew((p_args->>'id')::bigint, (p_args->>'claim')::uuid), false))
    when 'fetching'     then coalesce((select jsonb_agg(distinct plant) from billing.history_fetches
                                        where status in ('queued', 'running')), '[]'::jsonb)
    when 'login_seen'   then billing.login_seen((p_args->>'login')::uuid, p_args->'plants')
    when 'alerts'       then billing.alerts()
    when 'heartbeat'    then (select '{}'::jsonb from (select billing.heartbeat(p_args->>'job', now(), p_args->'result',
                               p_args->>'error')) x)
    when 'winback'      then billing.winback_return(p_args->>'reference')
    when 'outbox_sweep' then billing.outbox_sweep()
    when 'outbox_take'  then billing.outbox_take(coalesce((p_args->>'limit')::int, 50))
    when 'outbox_done'  then (select '{}'::jsonb from (select billing.outbox_done((p_args->>'id')::bigint,
                               (p_args->>'ok')::boolean, p_args->>'error', (p_args->>'retry_s')::int)) x)
    else billing.unknown_command(p_cmd)
  end;
end $$;

revoke all on all tables in schema billing from public, anon, authenticated;
grant select on all tables in schema billing to service_role;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'billing' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
revoke all on function public.api_account_state() from public, anon;
revoke all on function public.api_choose_plants(bigint[]) from public, anon;
revoke all on function public.api_plan_quote(text, text) from public, anon;
grant execute on function public.api_account_state() to authenticated;
grant execute on function public.api_choose_plants(bigint[]) to authenticated;
grant execute on function public.api_plan_quote(text, text) to authenticated;
revoke all on function public.billing_links(text, jsonb) from public, anon, authenticated;
grant execute on function public.billing_links(text, jsonb) to service_role;
revoke all on function public.q_upsert_plant_energy_v2(bigint, bigint, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.q_upsert_plant_energy_v2(bigint, bigint, jsonb, timestamptz) to service_role;
revoke all on function private.email_queue_old_billing() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The switch-over pause (DEPLOY.md "Billing switch-over"). 'new_payments': no new old-billing
-- payment starts (a row added to billing_charges), so open ones can be settled; 'all': no
-- write to any old billing table, so the last copy and switch_on see a still picture. Old
-- write paths fail with "billing is paused for an update" (the old billing function answers
-- an error; Paystack sends a refused webhook again later). resume_old ends it.
-- Every old write takes a shared advisory lock (7, 641) for the rest of its transaction;
-- pause_old takes it exclusive, so it waits for the writes already under way to commit and
-- the ones after it read the pause. The final copy then misses nothing.
-- ---------------------------------------------------------------------------
create table billing.old_pause (
  id    boolean primary key default true check (id),
  level text not null check (level in ('new_payments', 'all')),
  since timestamptz not null default now()
);
revoke all on table billing.old_pause from public, anon, authenticated;
-- security definer: the writer (service_role, an old RPC) needs no right on billing.old_pause
create function private.old_billing_paused()
returns trigger language plpgsql security definer set search_path = '' as $$
declare lvl text;
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(7, 641);
  lvl := (select p.level from billing.old_pause p);
  if lvl = 'all' or (lvl = 'new_payments' and tg_table_name = 'billing_charges' and tg_op = 'INSERT') then
    raise exception 'billing is paused for an update' using errcode = '55000';
  end if;
  return null;
end $$;
do $$
declare t text;
begin
  foreach t in array array['billing', 'billing_charges', 'plant_picks', 'free_week_logins', 'plant_week', 'offer_members', 'offers'] loop
    execute format('create trigger old_billing_paused before insert or update or delete on private.%I
                    for each statement execute function private.old_billing_paused()', t);
  end loop;
end $$;
create function billing.pause_old(p_level text)
returns jsonb language sql security definer set search_path = billing, pg_temp as $$
  select pg_advisory_xact_lock(7, 641);   -- waits for old writes under way (see above)
  insert into billing.old_pause (level) values (p_level)
  on conflict (id) do update set level = excluded.level, since = now()
  returning jsonb_build_object('paused', level, 'since', since)
$$;
create function billing.resume_old()
returns jsonb language sql security definer set search_path = billing, pg_temp as $$
  with d as (delete from billing.old_pause returning 1) select jsonb_build_object('resumed', exists (select 1 from d))
$$;
revoke all on function private.old_billing_paused() from public, anon, authenticated;
revoke all on function billing.pause_old(text) from public, anon, authenticated;
revoke all on function billing.resume_old() from public, anon, authenticated;

notify pgrst, 'reload schema';
