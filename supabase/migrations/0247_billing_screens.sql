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
           'logins', coalesce((select jsonb_agg(l.id order by l.created_at) from billing.logins l
                                 join billing.login_plants lp on lp.login = l.id
                                where l.account = p_account and lp.plant = (p->>'plant')::bigint and lp.gone_at is null), '[]'::jsonb),
           'claimed', exists (select 1 from billing.plant_claims c where c.account = p_account and c.plant = (p->>'plant')::bigint))
         order by (p->>'plant')::bigint), '[]'::jsonb)
    into plants from jsonb_array_elements(s->'plants') p;

  return s || jsonb_build_object(
    'plants', plants,
    'time_zone', coalesce(a.time_zone, m.default_time_zone),
    'locale', a.locale,
    'plan_name', (select name from billing.plans where code = s->>'plan'),
    'next_plan_name', (select name from billing.plans where code = s->>'next_plan'),
    'next_places', next_places,
    'fit_all_name', (select name from billing.plans where code = s->>'fit_all_plan'),
    'last_plan', last_sub.plan,
    'last_plan_name', (select name from billing.plans where code = last_sub.plan),
    'had_plan', last_sub.id is not null,
    'retention_days', m.retention_days,
    'trial_places', m.trial_places,
    -- the free week's last two days; a booked cancel's last three
    'trial_ends_soon', s->>'state' = 'trialing' and (s->>'trial_ends_at')::timestamptz - p_at <= interval '2 days',
    'cancel_soon', (s->>'cancel_at')::timestamptz - p_at <= interval '3 days',
    -- what a cancel booked now would mean: the history goes this long after the plan ends
    'if_cancelled_delete_at', case when sub.id is not null and not sub.cancel_at_period_end
                                   then sub.period_end + make_interval(days => m.retention_days) end,
    -- the latest "kept until" among the account's plants (null: nothing waits to be deleted)
    'history_kept_until', (select max((p->>'delete_at')::timestamptz) from jsonb_array_elements(plants) p
                            where p->>'delete_at' is not null and (p->>'delete_at')::timestamptz > p_at),
    'history_purged', exists (select 1 from jsonb_array_elements(plants) p where (p->>'purged')::boolean),
    'prices', prices,
    'logins', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'brand', l.brand, 'username', l.username,
                          'status', l.status) order by l.created_at)
                          from billing.logins l where l.account = p_account), '[]'::jsonb),
    'bills', coalesce((select jsonb_agg(b order by b->>'paid_at' desc) from (
                select jsonb_build_object('id', i.id, 'kind', i.kind, 'plan', i.plan,
                         'plan_name', (select name from billing.plans where code = i.plan), 'interval', i.interval,
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
    days_left := (s.period_end at time zone m.default_time_zone)::date - (p_at at time zone m.default_time_zone)::date;
    days_all := (s.period_end at time zone m.default_time_zone)::date - (s.period_start at time zone m.default_time_zone)::date;
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
  if holder is null then
    if st.state = 'ended' and not billing.has_route(p_account, p_plant, false) then
      raise exception 'no plant can be added without a plan' using errcode = '22023';
    end if;
    insert into billing.plant_claims (plant, account, claimed_at) values (p_plant, p_account, p_at);
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
                        'login_known', exists (select 1 from billing.logins l where l.account = acc and l.username = p_args->>'username'))
    -- the vault id is the stored login's own (private.sunsynk_accounts)
    when 'link_login' then billing.link_login(acc, coalesce(p_args->>'brand', 'sunsynk'), p_args->>'username',
                             (select sa.refresh_secret_id from private.sunsynk_accounts sa where sa.id = (p_args->>'login')::uuid),
                             p_args->'plants', now(), 'owner', (p_args->>'login')::uuid)
    when 'claim_plant' then billing.claim_plant(acc, (p_args->>'plant')::bigint, p_args->>'name')
    else billing.unknown_command(p_cmd)
  end;
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

-- A renewal try failed (not the copy's seed tries): the failed-card email. A hard decline
-- has its card_update email instead (queued by apply_payment).
create function billing.outbox_on_attempt()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
declare inv billing.invoices;
begin
  if new.status = 'failed' and (tg_op = 'INSERT' or old.status is distinct from 'failed')
     and new.gateway_response is distinct from 'copied: failed before the switch-over' and not new.hard_decline then
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
  if new.status = 'processed' and old.status is distinct from 'processed'
     and new.reason not in ('card_check', 'reversed', 'unknown_account') then
    perform billing.outbox_put(new.account, 'refund', null, new.id::text, 'refund:' || new.id, new.updated_at, null, new.updated_at);
  end if;
  return null;
end $$;
create trigger refunds_outbox after update of status on billing.refunds
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

-- A new card on an account that had one: card changed.
create function billing.outbox_on_card()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
begin
  if new.active and new.account is not null
     and exists (select 1 from billing.payment_methods pm where pm.account = new.account and pm.id <> new.id) then
    perform billing.outbox_put(new.account, 'card_changed', null, new.id::text, 'card_changed:' || new.id,
                               new.created_at, new.created_at + interval '2 days', new.created_at);
  end if;
  return null;
end $$;
create trigger payment_methods_outbox after insert on billing.payment_methods
  for each row execute function billing.outbox_on_card();

-- An owner's booked change or its undo. Sent 2 minutes later, so a quick change of mind
-- sends only the last one (the guard drops any but the latest).
create function billing.outbox_on_event()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
begin
  if new.actor = 'owner' and new.kind in ('cancel', 'undo_cancel', 'downgrade', 'switch_interval') then
    perform billing.outbox_put(new.account,
      case when new.kind = 'undo_cancel'
             or (new.kind = 'downgrade' and new.after->>'plan' = new.before->>'plan'
                 and new.after->>'extras' = new.before->>'extras') then 'change_undone' else 'change_booked' end,
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
      if st.access_ended_at = st.trial_ends_at and not exists (select 1 from billing.subscriptions x where x.account = a.id) then
        perform billing.outbox_put(a.id, 'trial_ended', null, extract(epoch from st.trial_ends_at)::bigint::text,
          'trial_ended:' || a.id || ':' || extract(epoch from st.trial_ends_at)::bigint, p_at, p_at + interval '2 days', p_at);
      end if;
      foreach d in array array[14, 27] loop
        if p_at >= st.access_ended_at + make_interval(days => d) and p_at < st.access_ended_at + make_interval(days => d + 2) then
          s := billing.account_state(a.id, p_at);
          kept := (select max((p->>'delete_at')::timestamptz) from jsonb_array_elements(s->'plants') p
                    where (p->>'delete_at')::timestamptz > p_at);
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
      if st.state not in ('active', 'past_due') then return 'plan over'; end if;
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
      if (billing.active_method(o.account)).id is distinct from o.ref::uuid then return 'card replaced'; end if;
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
                      where (p->>'delete_at')::timestamptz > p_at) then return 'nothing kept'; end if;
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
                'kind', inv.kind, 'plan', inv.plan, 'plan_name', (select name from billing.plans where code = inv.plan),
                'interval', inv.interval, 'amount_minor', inv.amount_minor, 'currency', inv.currency,
                'next_amount_minor', inv.plan_amount_minor + inv.extra_places * inv.extra_place_minor,
                'period_start', inv.period_start, 'period_end', inv.period_end, 'paid_at', inv.paid_at,
                'reference', att.reference, 'card_type', pm.card_type, 'last4', pm.last4) end,
      'refund', (select jsonb_build_object('amount_minor', coalesce(r.amount_minor, pa.amount_minor), 'currency',
                         coalesce(r.currency, pa.currency), 'reference', r.reference, 'reason', r.reason,
                         'paid_at', pa.settled_at, 'paid_minor', pa.amount_minor)
                   from billing.refunds r left join billing.payment_attempts pa on pa.id = r.attempt
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
                               coalesce((p_args->>'failed')::boolean, false), coalesce((p_args->>'throttled')::boolean, false))
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

notify pgrst, 'reload schema';
