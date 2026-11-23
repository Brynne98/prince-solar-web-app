-- ============================================================================
-- 0260 — billing redesign: drop the old billing (SOLAR-641).
--
-- NOT a migration yet: it lives outside supabase/migrations so `supabase db push` does not
-- run it. Run it only after the switch-over (DEPLOY.md, "Billing switch-over", step 8):
-- copy_from_old done and compared, billing.switch_on() run, the new frontend live. Then
-- move it to supabase/migrations/ under the next free number and push it. It refuses to run
-- before billing.switch_on().
--
-- Drops: private.billing, billing_charges, free_week_logins, offer_members, offers,
-- plant_picks (and its held flag), plant_week, plant_users.paused, every function they
-- feed, the old billing cron jobs, the old halves 0247 kept for before the switch, and the
-- one-off copy. Rewrites without the old tables the functions that still run: reading
-- (my_plant_ids, live_plants, plant_row_guard), emails (plant_live, pick_waiting, the
-- unchosen-plant skip, email_on_relink), linking (link_login_allowed, account_upsert,
-- plant_users_upsert, share_claim, plants_seen_before), screens (api_me, api_link_remove,
-- api_notifications) and account delete. Old billing emails still queued are skipped.
-- ============================================================================

do $$
begin
  if not billing.is_live() then
    raise exception 'run billing.switch_on() first (DEPLOY.md, Billing switch-over)' using errcode = '55000';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- The functions that still run, without the old tables
-- ---------------------------------------------------------------------------
-- The plants a user's account reads, for the edge functions: open seats only.
create or replace function public.chosen_plant_ids(p_user uuid)
returns bigint[] language sql stable security definer set search_path = public, private, pg_temp as $$
  select array(select se.plant from billing.seats se join billing.accounts a on a.id = se.account
                where a.user_id = p_user and se.closed_at is null
                  and billing.has_route(a.id, se.plant, false) order by se.plant)
$$;

create or replace function public.my_plant_ids()
returns setof bigint language sql stable security definer set search_path = public, private, pg_temp as $$
  select se.plant from billing.seats se join billing.accounts a on a.id = se.account
    join billing.plants p on p.id = se.plant
   where a.user_id = auth.uid() and se.closed_at is null and p.history_purged_at is null
     -- a share removed or a plant gone from the login: hidden; its history stays and shows again
     and billing.has_route(a.id, se.plant, false)
     -- not paying (ended, or over its places): its own history only, never a plant another
     -- account keeps, whose seat here never closes (it would see that payer's readings for good)
     and ((select st.state in ('trialing', 'active', 'past_due') and not st.must_choose
             from billing.account_status(a.id, now()) st)
          or not billing.kept_elsewhere(a.id, se.plant, now()))
$$;

create or replace function public.live_plants()
returns setof bigint language sql stable security definer set search_path = public, private, pg_temp as $$
  select distinct r.plant from billing.reading_routes(now()) r
$$;

create or replace function private.plant_row_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.plant_id is null then return new; end if;
  if current_setting('billing.guarded', true) = 'on' or tg_table_name in ('inverters', 'plant_config', 'meta')
     or coalesce((billing.plant_state(new.plant_id)->>'read_now')::boolean, false) then
    return new;
  end if;
  return null;
end $$;

create or replace function private.plant_live(p_user uuid, p_plant bigint)
returns boolean language sql stable set search_path = public, private, pg_temp as $$
  select coalesce(billing.reads_plant((select id from billing.accounts where user_id = p_user), p_plant, now()), false)
$$;

create or replace function private.pick_waiting(p_user uuid)
returns boolean language sql stable set search_path = public, private, pg_temp as $$
  select coalesce((select st.state = 'none' and st.linked > 0 and st.chosen = 0
                     from billing.accounts a cross join lateral billing.account_status(a.id, now()) st
                    where a.user_id = p_user), false)
$$;

create or replace function public.link_login_allowed(p_user uuid, p_username text)
returns boolean language sql stable security definer set search_path = public, private, pg_temp as $$
  select coalesce((select (billing.account_state(a.id)->>'may_add_login')::boolean
                          or exists (select 1 from billing.logins l where l.account = a.id and lower(l.username) = lower(p_username))
                     from billing.accounts a where a.user_id = p_user), true)
$$;

create or replace function private.email_skip_unchosen()
returns trigger language plpgsql security definer set search_path = '' as $$
declare acc uuid;
begin
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

-- A login that stops: its owners hear about the plants they choose (was: not paused).
do $$
declare d text := pg_get_functiondef('private.email_on_relink()'::regprocedure);
begin
  if position('and not pu.paused' in d) = 0 or position('order by pu.paused, pu.linked_at' in d) = 0 then
    raise exception 'email_on_relink changed since 0232: edit it by hand';
  end if;
  d := replace(d, 'and not pu.paused', 'and exists (select 1 from billing.seats se join billing.accounts ba on ba.id = se.account
                    where ba.user_id = pu.user_id and se.plant = pu.plant_id and se.closed_at is null)');
  d := replace(d, 'order by pu.paused, pu.linked_at', 'order by pu.linked_at');
  execute d;
end $$;

-- share_claim_live keeps account_upsert's lock order, which loses the old user lock below
do $$
declare d text := pg_get_functiondef('public.share_claim_live(uuid, uuid, bigint, text)'::regprocedure);
begin
  if position('perform private.billing_lock(p_user);' in d) = 0 then
    raise exception 'share_claim_live changed since 0247: edit it by hand';
  end if;
  execute replace(d, 'perform private.billing_lock(p_user);', '');
end $$;

create or replace function public.account_upsert(p_user uuid, p_username text, p_access text, p_expires bigint)
returns uuid language plpgsql security definer set search_path = private, pg_temp as $$
declare acc uuid;
begin
  -- plant_users_upsert's order (0170), so two links at once queue here and the second sees the first's login
  perform pg_advisory_xact_lock_shared(3, 0);
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

-- The website's prices (welcome-scene.js) and notify's preview, read from the billing tables:
-- the offer a new account would get now and list prices, in rand, in 0145's shape.
create or replace function public.api_offer()
returns jsonb language plpgsql stable security definer set search_path = billing, pg_temp as $$
declare
  m billing.markets := (select mk from billing.markets mk order by code limit 1);
  -- an account nobody has: what a new account is offered
  off text := billing.offer_for('00000000-0000-0000-0000-000000000000', now());
  o billing.offers := (select x from billing.offers x where x.code = off);
  list jsonb := '{}';
  at jsonb := '{}';
  iv text;
  r numeric;
begin
  for iv in select unnest(array['month', 'year']) loop
    list := list || jsonb_build_object(case iv when 'month' then 'monthly' else 'yearly' end, jsonb_build_object(
      'home', trim_scale((billing.price_for('home', m.code, iv, null, now())).amount_minor::numeric / 100),
      'family', trim_scale((billing.price_for('family', m.code, iv, null, now())).amount_minor::numeric / 100),
      'extra', trim_scale((billing.price_for('family', m.code, iv, null, now())).extra_place_minor::numeric / 100)));
    at := at || jsonb_build_object(case iv when 'month' then 'monthly' else 'yearly' end, jsonb_build_object(
      'home', trim_scale(coalesce((billing.price_for('home', m.code, iv, off, now())).amount_minor,
                                  (billing.price_for('home', m.code, iv, null, now())).amount_minor)::numeric / 100),
      'family', trim_scale(coalesce((billing.price_for('family', m.code, iv, off, now())).amount_minor,
                                    (billing.price_for('family', m.code, iv, null, now())).amount_minor)::numeric / 100),
      'extra', trim_scale(coalesce((billing.price_for('family', m.code, iv, off, now())).extra_place_minor,
                                   (billing.price_for('family', m.code, iv, null, now())).extra_place_minor)::numeric / 100)));
  end loop;
  return jsonb_build_object('prices', at, 'listPrices', list,
    'offer', case when off is not null then jsonb_build_object('id', o.code, 'months', null, 'cap', o.max_members,
               'joinsUntil', (o.valid_until at time zone m.default_time_zone)::date, 'held', false, 'until', null) end);
end $$;
revoke all on function public.api_offer() from public;
grant execute on function public.api_offer() to anon, authenticated;

-- The links (plant_users) only; which plants are chosen is billing.seats' (link_login,
-- set_chosen_plants), and the free week is billing.accounts'.
create or replace function public.plant_users_upsert(p_user uuid, p_account uuid, p_rows jsonb)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  p bigint;
  ids bigint[] := array(select (r->>'plant_id')::bigint from jsonb_array_elements(p_rows) r);
  login boolean;
  who text;
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  for p in select distinct x from unnest(ids) x order by 1 loop
    perform pg_advisory_xact_lock(p);
  end loop;
  select kind = 'login', sunsynk_username into login, who from private.sunsynk_accounts where id = p_account and status <> 'disabled';
  if not found then
    raise exception 'plant_users_upsert: account % is removed or disabled', p_account;
  end if;
  insert into public.plant_users (plant_id, user_id, account_id, plant_name)
  select (r->>'plant_id')::bigint, p_user, p_account, r->>'plant_name'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id, user_id) do update
    set account_id = excluded.account_id, plant_name = excluded.plant_name;
  if login and cardinality(ids) > 0 then
    update public.plant_users set share_missing_at = null, share_gone_at = null
     where account_id = p_account and user_id = p_user and not via_share and plant_id = any (ids)
       and (share_missing_at is not null or share_gone_at is not null);
    with g as (
      update public.plant_users set share_gone_at = now()
       where account_id = p_account and user_id = p_user and not via_share and share_gone_at is null
         and share_missing_at < now() - interval '50 minutes' and plant_id <> all (ids)
      returning user_id, plant_id, plant_name)
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    select g.user_id, g.plant_id, 'plant_off_login', 'plant_off_login:' || g.plant_id || ':' || extract(epoch from now())::bigint,
           jsonb_build_object('plants', jsonb_build_array(coalesce(g.plant_name, 'Plant ' || g.plant_id)), 'login', who), 1
      from g
    on conflict do nothing;
    update public.plant_users set share_missing_at = now()
     where account_id = p_account and user_id = p_user and not via_share and share_gone_at is null
       and share_missing_at is null and plant_id <> all (ids);
  end if;
  insert into public.app_config (key, value, note)
  select 'CALIBRATION_PLANT', (r->>'plant_id')::bigint,
         'the one plant the single-site forecast/alerts are bound to; set by the first link, then fixed'
    from jsonb_array_elements(p_rows) r order by (r->>'plant_id')::bigint limit 1
  on conflict (key) do nothing;
end $$;

-- A plant shared to our login: the link row; the claim itself is billing.claim_plant.
create or replace function public.share_claim(p_user uuid, p_account uuid, p_plant bigint, p_plant_name text)
returns text language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  mine public.plant_users;
  lapsed uuid[];
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and kind = 'share' and status <> 'disabled') then
    raise exception 'share_claim: % is not the share login', p_account;
  end if;
  perform pg_advisory_xact_lock_shared(3, 0);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  perform pg_advisory_xact_lock(p_plant);
  select * into mine from public.plant_users where plant_id = p_plant and user_id = p_user;
  if found and mine.share_gone_at is null then return 'yours'; end if;
  if exists (select 1 from public.plant_users o
              where o.plant_id = p_plant and o.user_id <> p_user and (not o.via_share or o.share_gone_at is null)) then
    return 'taken';
  end if;
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

-- SOLAR-584's count: plants that had their free week before this account was made, held by
-- no other account now.
create or replace function public.plants_seen_before(p_user uuid, p_plants bigint[])
returns integer language sql stable security definer set search_path = public, private, pg_temp as $$
  select count(*)::int
    from billing.plants p
   where p.id = any (coalesce(p_plants, '{}'))
     and p.trial_used_at < (select u.created_at from auth.users u where u.id = p_user)
     and not exists (select 1 from billing.seats se join billing.accounts a on a.id = se.account
                      where se.plant = p.id and se.closed_at is null and a.user_id <> p_user)
$$;

-- prefs and the plants to show; the plan, the free week and the pay screen are api_account_state's.
create or replace function public.api_me()
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object(
    'user', jsonb_build_object('id', auth.uid()),
    'prefs', coalesce((select prefs from public.profiles where user_id = auth.uid()), '{}'::jsonb),
    'plants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pu.plant_id, 'name', pu.plant_name, 'linkedAt', pu.linked_at,
               'config', to_jsonb(c) - 'plant_id' - 'updated_by')
             order by pu.linked_at, pu.plant_id)
        from public.plant_users pu
        left join public.plant_config c on c.plant_id = pu.plant_id
       where pu.user_id = auth.uid() and pu.plant_id in (select public.my_plant_ids())), '[]'::jsonb))
$$;

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
  return jsonb_build_object('result', 'removed');
end $$;

-- The bell's alerts; account notices come from api_account_state now (pinned stays, empty).
create or replace function public.api_notifications()
returns jsonb language sql stable security definer set search_path = '' as $$
  with n as (
    select q.id, q.kind, q.plant_id, pu.plant_name, q.read_at, q.created_at,
           private.alert_text(q.kind, q.data, q.created_at, public.plant_tz(q.plant_id)) t
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid()
       and q.plant_id in (select public.my_plant_ids())
       and private.is_alert(q.kind)
       and q.created_at > now() - interval '30 days'
     order by q.created_at desc, q.id desc
     limit 300)
  select jsonb_build_object(
    'pinned', '[]'::jsonb,
    'unread', (select count(*) from n where read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'plant', plant_id, 'plantName', plant_name, 'read', read_at is not null) || t
        order by created_at desc, id desc) from n), '[]'::jsonb));
$$;
create or replace function public.api_notices_read(p_keys text[] default null)
returns void language sql security definer set search_path = '' as $$ select $$;

create or replace function public.api_account_delete()
returns jsonb language plpgsql security definer set search_path = public, private, vault, pg_temp as $$
declare
  uid uuid := auth.uid();
  acc record;
  gone jsonb;
  orphans bigint[];
begin
  -- 0247's lock order, kept: the billing-run lock, then the lock of each login its links hang on
  -- (its own and the share login), then the link rows, then the account (billing.delete_account).
  -- A reconnect, a claim of a lapsed share and the poller's share update take them in this order;
  -- the other way round deadlocks (scripts/billing-lock-test.mjs)
  perform pg_advisory_xact_lock_shared(3, 0);
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  for acc in select x.id from (select id from private.sunsynk_accounts where user_id = uid
                               union select account_id from public.plant_users where user_id = uid and account_id is not null) x
              order by x.id loop
    perform pg_advisory_xact_lock(1, hashtext(acc.id::text));
  end loop;
  perform 1 from public.plant_users where user_id = uid order by plant_id for update;
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
  insert into public.email_queue (to_email, kind, key, priority)
  select email, 'account_deleted', 'account_deleted:' || uid, 1 from auth.users where id = uid and email is not null
  on conflict do nothing;
  delete from public.profiles where user_id = uid;
  delete from auth.users where id = uid;
  return jsonb_build_object('deleted', true, 'plantsRemoved', coalesce(cardinality(orphans), 0));
end $$;

-- the win-back return, from the new tables only
create or replace function public.winback_return(p_reference text)
returns table (user_id uuid, email_id bigint, days int, at timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  select (w->>'user')::uuid, (w->>'email_id')::bigint, (w->>'days')::int, (w->>'at')::timestamptz
    from (select billing.winback_return(p_reference) w) x
   where w is not null
$$;

-- ---------------------------------------------------------------------------
-- Old billing emails still queued: never sent (the outbox has their replacements)
-- ---------------------------------------------------------------------------
update public.email_queue set status = 'skipped', last_error = 'old billing email (SOLAR-641)'
 where status = 'queued' and billing.old_billing_email(kind);

-- ---------------------------------------------------------------------------
-- Old cron jobs
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobname) from cron.job
     where jobname in ('free-week-mail', 'card-expiry-mail', 'offer-end-mail', 'unpaid-delete', 'plant-wipe', 'free-trim',
                       'plant-purge');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Old triggers and functions
-- ---------------------------------------------------------------------------
drop trigger if exists plant_users_drop_pick on public.plant_users;
drop trigger if exists plant_users_plan_limit on public.plant_users;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'private' and p.proname in (
              'billing_charge_cancel_guard', 'billing_charge_stale', 'billing_dispute_apply', 'billing_drops', 'billing_fit',
              'billing_keep_list', 'billing_notices', 'billing_offer', 'billing_offer_json', 'billing_offer_now',
              'billing_offer_open', 'billing_refund_mail', 'billing_restart', 'billing_resume', 'billing_to_free',
              'billing_try_slot', 'billing_week_used', 'billing_winback', 'card_changed_mail', 'card_expiry_mail',
              'email_skip_paused', 'free_week_mail', 'had_plan', 'no_week', 'offer_end_mail', 'plant_in_week',
              'plant_pick_add', 'plant_run', 'plant_swap', 'plant_users_drop_pick', 'plant_users_plan_limit',
              'plant_wipe_readings', 'plant_wipes', 'unpaid_delete', 'unpaid_since', 'week_ends', 'week_start',
              'billing_price_list', 'billing_lock', 'billing_today', 'billing_end_day', 'plant_live_old', 'pick_waiting_old',
              'old_billing_paused'))
        or (n.nspname = 'public' and p.proname in (
              'api_billing_change', 'api_billing_extras', 'api_billing_keep', 'api_billing_keep_set', 'api_billing_quote',
              'api_billing_start_keep', 'api_billing_status', 'api_link_status', 'api_plant_pick', 'api_plant_picks',
              'email_prices', 'email_billing_facts', 'email_reversed_reference',
              'billing_amount', 'billing_amount_due', 'billing_book_change', 'billing_book_removal', 'billing_card_open',
              'billing_charge_disputed', 'billing_charge_failed', 'billing_charge_open', 'billing_charge_paid',
              'billing_charge_refund_event', 'billing_charge_refunded', 'billing_charge_user', 'billing_may_link',
              'billing_refunds_due', 'billing_renew', 'billing_room', 'billing_run', 'billing_run_release',
              'billing_set_comped', 'billing_settle_open', 'billing_start_facts', 'billing_upgrade_quote',
              'link_login_allowed_old', 'api_account_delete_old', 'poll_jobs'))
        or (n.nspname = 'billing' and p.proname in ('copy_from_old', 'pause_old', 'resume_old', 'switch_off', 'pause_payments'))
  loop
    execute format('drop routine %s cascade', f.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Old tables and columns
-- ---------------------------------------------------------------------------
drop table billing.old_pause;
drop table billing.old_jobs;
-- billing.payments_pause stays: begin_attempt and run read it (always empty once here)
drop table private.billing_charges cascade;
drop table private.billing cascade;
drop table private.offer_members cascade;
drop table private.offers cascade;
drop table private.plant_picks cascade;
drop table private.plant_week cascade;
drop table private.free_week_logins cascade;
alter table public.plant_users drop column paused;

-- Nothing left may read what went. "paused" under any alias counts; not a quoted answer key
-- ('paused' in api_logins) and not plant_config_seed, whose paused is a field of its own rows.
do $$
declare bad text;
begin
  select string_agg(n.nspname || '.' || p.proname, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private', 'billing')
     and (p.prosrc ~ '(private\.billing\M|billing_charges|free_week_logins|offer_members|private\.offers|plant_picks|plant_week)'
          or (replace(p.prosrc, '''paused''', '') ~ '\mpaused\M' and p.proname <> 'plant_config_seed'));
  if bad is not null then raise exception 'still reading the old billing: %', bad; end if;
  -- nor call a function that went
  select string_agg(distinct n.nspname || '.' || p.proname || ' calls ' || d.x, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    cross join unnest(array['billing_lock', 'billing_today', 'billing_end_day', 'billing_room', 'billing_amount', 'week_ends',
                            'week_start', 'plant_in_week', 'plant_pick_add', 'plant_run', 'billing_notices', 'billing_offer_json',
                            'billing_offer_open', 'billing_offer_now', 'unpaid_since', 'had_plan', 'no_week', 'plant_wipe_readings',
                            'api_billing_status', 'api_link_status', 'poll_jobs', 'billing_drops', 'billing_price_list',
                            'email_prices', 'email_billing_facts', 'copy_from_old']) d (x)
   where n.nspname in ('public', 'private', 'billing') and p.prosrc ~ ('\m' || d.x || '\s*\(')
     and not (p.proname = 'poll_jobs_v2' and d.x = 'poll_jobs');    -- its branch for before the switch, never taken now
  if bad is not null then raise exception 'still calling the old billing: %', bad; end if;
end $$;

notify pgrst, 'reload schema';
