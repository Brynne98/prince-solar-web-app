-- ============================================================================
-- 0127 — one place sets the plant limit, and the server prices every charge
-- (SOLAR-264, plan approved 2026-10-30).
--
-- Plant limit. private.plant_users_plan_limit (0110's trigger) now runs on every
-- plant that starts to collect: a new row, or paused going false. Under a per-user
-- lock, so parallel links and starts wait their turn, Free or not. It counts every
-- collecting plant, those booked for removal too: they collect and are billed until
-- their date.
--   - Free and Home: 1 plant. Family: 3, more only from billing_resume after the
--     R49 an inverter is paid. Comped: no limit.
--   - A booked downgrade or cancel: no more than the booked plan takes, plants
--     booked for removal left out (as billing_book_change counts).
--   - Over the limit, a new row links stopped; a start raises 'no room' or 'plan
--     change' (api_plant_start's errors, so the app is unchanged).
-- billing_renew fits the plants to the new plan on the billing date (billing_fit): a
-- downgrade booked before more plants came in still ends with 1 collecting.
--
-- Charges. billing_charge_open no longer takes the app's inverter count: it counts
-- the inverters of the stopped plants the charge names that land past the 3rd (a
-- plant with no inverter rows counts as 1). The charge keeps the billing date it was
-- opened for. billing_charge_paid works the charge out again; when the account has
-- moved on (another billing date, other plants, another price), the money is marked
-- for refund and nothing changes. A renewal or settle applies only to the billing
-- date it is for. An upgrade that keeps the plan keeps a booked change.
--
-- Also: a paid account's first link starts its free week too, so a later move to
-- Free trims like any Free account; the saved card is charged with the email it was
-- saved with (card_email); billing_charge_user for /billing/verify.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The limit
-- ---------------------------------------------------------------------------
create or replace function private.billing_lock(p_user uuid)
returns void language sql as $$
  select pg_advisory_xact_lock(2, hashtext(p_user::text))
$$;
revoke all on function private.billing_lock(uuid) from public, anon, authenticated;

create or replace function private.plant_users_plan_limit()
returns trigger language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  act int;
  kept int;
  why text;
begin
  if new.paused or (tg_op = 'UPDATE' and not old.paused) then return new; end if;
  -- A row already linked (the hourly sync's upsert): ON CONFLICT keeps its paused.
  if tg_op = 'INSERT' and exists (select 1 from public.plant_users where user_id = new.user_id and plant_id = new.plant_id) then
    return new;
  end if;
  perform private.billing_lock(new.user_id);
  -- after the lock: what the transaction before us committed
  select * into b from private.billing where user_id = new.user_id;
  if coalesce(b.comped, false) then return new; end if;
  select count(*), count(*) filter (where plant_id <> all (coalesce(b.plants_to_remove, '{}')))
    into act, kept
    from public.plant_users
   where user_id = new.user_id and not paused and plant_id <> new.plant_id;
  if act >= coalesce(public.billing_plant_limit(coalesce(b.plan, 'free')), 3)
     and not (coalesce(b.plan, 'free') = 'family' and coalesce(current_setting('billing.paid_start', true), '') = 'on') then
    why := 'no room';
  elsif b.next_plan is not null and kept >= coalesce(public.billing_plant_limit(b.next_plan), 2147483647) then
    why := 'plan change';
  else
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.paused := true;
    return new;
  end if;
  raise exception '%', why using errcode = '22023';
end $$;
revoke all on function private.plant_users_plan_limit() from public, anon, authenticated;
drop trigger if exists plant_users_plan_limit on public.plant_users;
create trigger plant_users_plan_limit before insert or update of paused on public.plant_users
  for each row execute function private.plant_users_plan_limit();

-- 0096's upsert, taking the user's lock first. The trigger takes it per row, after the
-- plant locks here; a start takes it before the plant's (plant_start_fill). Two orders
-- deadlocked a link against a start; one order now: user, then login, then plants.
create or replace function public.plant_users_upsert(p_user uuid, p_account uuid, p_rows jsonb)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare p bigint;
begin
  perform private.billing_lock(p_user);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  for p in select distinct (r->>'plant_id')::bigint from jsonb_array_elements(p_rows) r order by 1 loop
    perform pg_advisory_xact_lock(p);
  end loop;
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and status <> 'disabled') then
    raise exception 'plant_users_upsert: account % is removed or disabled', p_account;
  end if;
  for p in
    select g.plant_id from private.plant_purge g
     where g.plant_id in (select (r->>'plant_id')::bigint from jsonb_array_elements(p_rows) r)
     order by g.plant_id
  loop
    raise notice 'plant % relinked while waiting to be purged: wiping first (%)', p, private.purge_plant(p);
  end loop;

  insert into public.plant_users (plant_id, user_id, account_id, plant_name)
  select (r->>'plant_id')::bigint, p_user, p_account, r->>'plant_name'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id, user_id) do update
    set account_id = excluded.account_id, plant_name = excluded.plant_name;

  insert into public.app_config (key, value, note)
  select 'CALIBRATION_PLANT', (r->>'plant_id')::bigint,
         'the one plant the single-site forecast/alerts are bound to; set by the first link, then fixed'
    from jsonb_array_elements(p_rows) r
   order by (r->>'plant_id')::bigint
   limit 1
  on conflict (key) do nothing;
end $$;
revoke all on function public.plant_users_upsert(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.plant_users_upsert(uuid, uuid, jsonb) to service_role;

-- The plan's limit, applied on the billing date: Free and Home keep 1 plant, the first
-- linked that is not about to be deleted. Family keeps its extras: renewal bills them.
create or replace function private.billing_fit(p_user uuid, p_going bigint[])
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare lim int;
begin
  perform private.billing_lock(p_user);
  if exists (select 1 from private.billing where user_id = p_user and comped) then return; end if;
  lim := public.billing_plant_limit(coalesce((select plan from private.billing where user_id = p_user), 'free'));
  if lim is null then return; end if;
  update public.plant_users set paused = true
   where user_id = p_user and plant_id in (
     select plant_id from public.plant_users
      where user_id = p_user and not paused
      order by plant_id = any (p_going), linked_at, plant_id
     offset lim);
end $$;
revoke all on function private.billing_fit(uuid, bigint[]) from public, anon, authenticated;

-- 0125's start, the checks now in the trigger.
create or replace function public.api_plant_start(p_plant bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare others boolean;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if not exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = p_plant) then
    raise exception 'plant % is not linked to this user', p_plant using errcode = '42501';
  end if;
  others := exists (select 1 from public.plant_users where plant_id = p_plant and not paused);
  update public.plant_users set paused = false where user_id = auth.uid() and plant_id = p_plant and paused;
  -- Already collecting, or someone else collects it: its readings are there already.
  if found and not others then perform private.plant_start_fill(p_plant); end if;
  return jsonb_build_object('started', true);
end $$;

-- Unpaid on day 8 (0116): the others stop first, then the kept plant starts, so the
-- trigger never sees two collecting on Free.
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
  update public.plant_users set paused = true where user_id = p_user and plant_id is distinct from keep and not paused;
  update public.plant_users set paused = false where user_id = p_user and plant_id = keep and paused;
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (p_user, 'bill_free', 'bill_free:' || p_today,
          jsonb_build_object('from', b.plan, 'deleteOn', p_today + 30,
            'kept', coalesce((select plant_name from public.plant_users where user_id = p_user and plant_id = keep), ''),
            'stopped', coalesce((select jsonb_agg(plant_name order by linked_at) from public.plant_users
                                  where user_id = p_user and plant_id = any (stop)), '[]'::jsonb)),
          1)
  on conflict do nothing;
end $$;

-- 0110's renewal, then the plants fitted to the plan it leaves.
create or replace function public.billing_renew(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  due int;
  v_plan text; v_period text;
  going bigint[];
begin
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' or b.comped then
    raise exception 'nothing to renew on Free' using errcode = '22023';
  end if;
  due := public.billing_amount_due(p_user);
  v_plan := coalesce(b.next_plan, b.plan);
  v_period := coalesce(b.next_period, b.period);
  going := case when b.remove_on <= b.next_billing_date then b.plants_to_remove else '{}' end;
  update private.billing
     set plan = v_plan,
         period = case when v_plan = 'free' then null else v_period end,
         billing_day = case when v_plan = 'free' then null else b.billing_day end,
         next_billing_date = case when v_plan = 'free' then null
                             else public.billing_step(b.next_billing_date, v_period, b.billing_day, 1) end,
         next_plan = null, next_period = null, updated_at = now()
   where user_id = p_user;
  perform private.billing_fit(p_user, going);
  return jsonb_build_object('charge', due, 'plan', v_plan, 'removePlants', to_jsonb(going));
end $$;

-- 0110's booking, under the same lock as the trigger: a link can't slip in between.
create or replace function public.billing_book_change(p_user uuid, p_plan text, p_period text default null)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  rank constant jsonb := '{"free": 0, "home": 1, "family": 2}';
  keep int;
begin
  select * into b from private.billing where user_id = p_user for update;
  perform private.billing_lock(p_user);
  if b.plan is null or b.plan = 'free' then
    raise exception 'nothing to change on Free' using errcode = '22023';
  end if;
  if b.comped then
    raise exception 'this plan is free of charge' using errcode = '22023';
  end if;
  if (rank->>p_plan)::int > (rank->>b.plan)::int then
    raise exception 'an upgrade starts at once, not at the billing date' using errcode = '22023';
  end if;
  keep := (select count(*) from public.plant_users
            where user_id = p_user and not paused and plant_id <> all (b.plants_to_remove));
  if keep > coalesce(public.billing_plant_limit(p_plan), 2147483647) then
    raise exception 'remove plants first' using errcode = '22023';
  end if;
  update private.billing
     set next_plan   = case when p_plan = b.plan then null else p_plan end,
         next_period = case when p_plan = 'free' or coalesce(p_period, b.period) = b.period then null
                            else p_period end,
         updated_at  = now()
   where user_id = p_user;
end $$;

-- 0113's keep, under the lock too.
create or replace function public.api_billing_keep(p_plant bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid() for update;
  perform private.billing_lock(auth.uid());
  if b.next_plan is not null
     and (select count(*) from public.plant_users
           where user_id = auth.uid() and not paused
             and (plant_id = p_plant or plant_id <> all (b.plants_to_remove)))
         > coalesce(public.billing_plant_limit(b.next_plan), 2147483647) then
    raise exception 'needed for your plan change' using errcode = '22023';
  end if;
  update private.billing
     set plants_to_remove = array_remove(plants_to_remove, p_plant),
         remove_on = case when array_remove(plants_to_remove, p_plant) = '{}' then null else remove_on end,
         updated_at = now()
   where user_id = auth.uid();
  return public.api_billing_status();
end $$;

-- 0121's link check. Plants booked for removal count: they collect until their date,
-- and the trigger counts them. The answer names the plan, so link-sunsynk knows a
-- stopped Family plant is one to pay for.
create or replace function public.billing_may_link(p_user uuid, p_sunsynk_username text, p_plant_inverters int[])
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  v_plan text := coalesce((select b.plan from private.billing b where b.user_id = p_user), 'free');
  have int := (select count(*) from public.plant_users where user_id = p_user and not paused);
  extra int;
begin
  -- Never billed: no limit, extra inverters cost nothing.
  if exists (select 1 from private.billing b where b.user_id = p_user and b.comped) then
    return jsonb_build_object('ok', true, 'plan', v_plan, 'comped', true, 'extraInverters', 0, 'dueNow', 0);
  end if;
  select coalesce(sum(greatest(n, 1)), 0) into extra
    from unnest(p_plant_inverters) with ordinality as t(n, i) where have + i > 3;
  if have + coalesce(cardinality(p_plant_inverters), 0) > coalesce(public.billing_plant_limit(v_plan), 2147483647) then
    return jsonb_build_object('ok', false, 'plan', v_plan, 'reason', 'upgrade_needed', 'extraInverters', extra);
  end if;
  return jsonb_build_object('ok', true, 'plan', v_plan, 'extraInverters', extra,
    'dueNow', case when v_plan = 'family' and extra > 0
                   then (public.billing_upgrade_quote(p_user, 'family', extra))->'dueNow' else '0' end);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Prices
-- ---------------------------------------------------------------------------
-- 0110's count, with a plant that has no inverter rows (seed failed) as 1.
create or replace function public.billing_extra_inverters(p_user uuid, p_skip bigint[] default '{}')
returns int language sql stable security definer set search_path = public, private, pg_temp as $$
  select coalesce(sum(greatest((select count(*) from private.inverters i where i.plant_id = p.plant_id), 1)), 0)::int
    from (select plant_id, row_number() over (order by linked_at, plant_id) as n
            from public.plant_users
           where user_id = p_user and not paused and plant_id <> all (p_skip)) p
   where p.n > 3
$$;

-- The inverters a charge adds on Family: what billing_extra_inverters counts once the
-- user's stopped plants in p_plants collect too, less what it counts now. The bill
-- orders all collecting plants by link date, so this is what the next bill adds.
create or replace function private.billing_named_added(p_user uuid, p_plan text, p_plants bigint[])
returns int language sql stable set search_path = public, private, pg_temp as $$
  select case when p_plan <> 'family' then 0 else
    (select coalesce(sum(greatest((select count(*) from private.inverters i where i.plant_id = p.plant_id), 1)), 0)::int
       from (select plant_id, row_number() over (order by linked_at, plant_id) as n
               from public.plant_users
              where user_id = p_user and (not paused or plant_id = any (coalesce(p_plants, '{}')))) p
      where p.n > 3)
    - public.billing_extra_inverters(p_user) end
$$;
revoke all on function private.billing_named_added(uuid, text, bigint[]) from public, anon, authenticated;

-- 0110's paywall figures. p_plants: the stopped plants to start, priced as the charge
-- prices them. p_added is only read without p_plants: a link not made yet.
drop function if exists public.api_billing_quote(text, text, int);
create or replace function public.api_billing_quote(p_plan text, p_period text default 'monthly', p_added int default 0,
  p_plants bigint[] default null)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid();
  return jsonb_build_object('plan', coalesce(b.plan, 'free'), 'period', b.period,
           'extraPrice', public.billing_amount('family', coalesce(b.period, p_period), 1)
                         - public.billing_amount('family', coalesce(b.period, p_period), 0))
      || public.billing_upgrade_quote(auth.uid(), p_plan,
           case when p_plants is not null then private.billing_named_added(auth.uid(), p_plan, p_plants)
                else greatest(p_added, 0) end,
           case when coalesce(b.plan, 'free') = 'free' then p_period end);
end $$;
revoke all on function public.api_billing_quote(text, text, int, bigint[]) from public, anon;
grant execute on function public.api_billing_quote(text, text, int, bigint[]) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Charges
-- ---------------------------------------------------------------------------
-- The billing date a start or upgrade was priced for (null on Free). Charges still open
-- from before this get their account's date, so paying them is judged as before.
alter table private.billing_charges add column if not exists billing_date date;
update private.billing_charges c set billing_date = b.next_billing_date
  from private.billing b
 where b.user_id = c.user_id and c.status = 'pending' and c.kind in ('start', 'upgrade') and c.billing_date is null;

drop function if exists public.billing_charge_open(uuid, text, text, int, bigint[]);
create or replace function public.billing_charge_open(
  p_user uuid, p_plan text, p_period text default null, p_plants bigint[] default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  q jsonb;
  ref text := 'psh_' || replace(gen_random_uuid()::text, '-', '');
  v_kind text;
  v_period text;
  named bigint[];
  added int;
  today date := private.billing_today();
begin
  select * into b from private.billing where user_id = p_user for update;
  perform private.billing_lock(p_user);
  if b.comped then raise exception 'this plan is free of charge' using errcode = '22023'; end if;
  if b.state = 'past_due' then raise exception 'settle the failed payment first' using errcode = '22023'; end if;
  v_kind := case when coalesce(b.plan, 'free') = 'free' then 'start' else 'upgrade' end;
  v_period := case when v_kind = 'start' then coalesce(p_period, 'monthly') else b.period end;
  if v_period not in ('monthly', 'yearly') or p_plan not in ('home', 'family') then
    raise exception 'unknown plan or period' using errcode = '22023';
  end if;
  -- Only this user's stopped plants; anything else in the list is dropped.
  named := array(select pu.plant_id from public.plant_users pu
                  where pu.user_id = p_user and pu.paused and pu.plant_id = any (coalesce(p_plants, '{}'))
                  order by pu.linked_at, pu.plant_id);
  if cardinality(named) = 0 then
    -- Asked to start plants on the plan held, and none of them is stopped now: nothing to buy.
    if cardinality(p_plants) > 0 and v_kind = 'upgrade' and p_plan = b.plan then
      raise exception 'nothing to start' using errcode = '22023';
    end if;
    named := null;
  end if;
  -- More plants on the same plan with a downgrade booked: the booked plan has no room.
  if named is not null and b.next_plan is not null and p_plan = b.plan then
    raise exception 'plan change' using errcode = '22023';
  end if;
  added := private.billing_named_added(p_user, p_plan, named);
  q := public.billing_upgrade_quote(p_user, p_plan, added, case when v_kind = 'start' then v_period end, today);
  insert into private.billing_charges (reference, user_id, kind, plan, period, added, plants, amount, due_on, created_on, billing_date)
  values (ref, p_user, v_kind, p_plan, v_period, added, named, greatest((q->>'dueNow')::int, 0), today, today, b.next_billing_date);
  if (q->>'dueNow')::int <= 0 then
    perform public.billing_charge_paid(ref, null, true);
    return jsonb_build_object('amount', 0, 'reference', ref);
  end if;
  return jsonb_build_object('reference', ref, 'amount', (q->>'dueNow')::int,
    'email', (select email from auth.users where id = p_user),
    'card', b.card->>'authorization_code',
    -- Paystack charges a saved card only with the email it was saved with.
    'cardEmail', coalesce(b.card_email, (select email from auth.users where id = p_user)));
end $$;
revoke all on function public.billing_charge_open(uuid, text, text, bigint[]) from public, anon, authenticated;
grant execute on function public.billing_charge_open(uuid, text, text, bigint[]) to service_role;

-- Start stopped plants after a paid start or upgrade. p_plants: the plants the charge
-- names, in link order; Family plants past the 3rd among them are paid for, so the
-- trigger lets them in. None named: the oldest stopped, while the plan has room.
drop function if exists private.billing_resume(uuid, text, int, bigint[]);
create or replace function private.billing_resume(p_user uuid, p_plants bigint[])
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  r record;
  others boolean;
begin
  perform set_config('billing.paid_start', case when p_plants is null then 'off' else 'on' end, true);
  for r in select pu.plant_id from public.plant_users pu
            where pu.user_id = p_user and pu.paused and (p_plants is null or pu.plant_id = any (p_plants))
            order by pu.linked_at, pu.plant_id loop
    others := exists (select 1 from public.plant_users where plant_id = r.plant_id and not paused);
    begin
      update public.plant_users set paused = false where user_id = p_user and plant_id = r.plant_id;
    exception when sqlstate '22023' then
      exit;  -- the plan is full
    end;
    if not others then perform private.plant_start_fill(r.plant_id); end if;
    -- A plant stopped by a move to Free and now resumed is no longer up for deletion;
    -- the ones still paused stay booked. At once, so the next plant's check counts it kept.
    update private.billing
       set plants_to_remove = array_remove(plants_to_remove, r.plant_id),
           remove_on = case when array_remove(plants_to_remove, r.plant_id) = '{}' then null else remove_on end
     where user_id = p_user and r.plant_id = any (plants_to_remove);
  end loop;
  perform set_config('billing.paid_start', 'off', true);
end $$;
revoke all on function private.billing_resume(uuid, bigint[]) from public, anon, authenticated;

-- Why a paid charge no longer fits the account, or null when it does.
create or replace function private.billing_charge_stale(c private.billing_charges, b private.billing)
returns text language plpgsql stable set search_path = public, private, pg_temp as $$
declare
  q jsonb;
  added int;
begin
  if c.kind in ('renewal', 'settle') then
    -- Past due for this billing date, or (a renewal reported paid on its day) the
    -- period it opened is the one running now.
    if b.state = 'past_due' and c.due_on = b.past_due_since then return null; end if;
    if c.kind = 'renewal' and c.status = 'pending' and b.state = 'active' and b.plan <> 'free' and not b.comped
       and c.due_on = public.billing_step(b.next_billing_date, b.period, b.billing_day, -1)
       and not exists (select 1 from private.billing_charges x
                        where x.user_id = c.user_id and x.kind in ('renewal', 'settle') and x.due_on = c.due_on
                          and x.status = 'paid' and x.error is null and x.reference <> c.reference) then
      return null;
    end if;
    return 'not due';
  end if;
  if c.kind = 'start' and coalesce(b.plan, 'free') <> 'free' then return 'not on Free'; end if;
  if c.kind = 'upgrade' and (coalesce(b.plan, 'free') = 'free' or b.state = 'past_due' or b.period is distinct from c.period) then
    return 'plan changed';
  end if;
  if c.billing_date is distinct from b.next_billing_date then return 'billing date passed'; end if;
  if c.plants is not null and b.next_plan is not null and c.plan = b.plan then return 'plan change booked'; end if;
  added := private.billing_named_added(c.user_id, c.plan, c.plants);
  if added <> c.added then return 'plants changed'; end if;
  begin
    q := public.billing_upgrade_quote(c.user_id, c.plan, added, case when c.kind = 'start' then c.period end, c.created_on);
  exception when sqlstate '22023' then
    return 'not an upgrade';
  end;
  if greatest((q->>'dueNow')::int, 0) <> c.amount then return 'price changed'; end if;
  return null;
end $$;
revoke all on function private.billing_charge_stale(private.billing_charges, private.billing) from public, anon, authenticated;

-- 0126's paid, with the whole check in billing_charge_stale.
create or replace function public.billing_charge_paid(p_reference text, p_card jsonb default null,
  p_quiet boolean default false, p_cents bigint default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  today date := private.billing_today();
  v_from text;
  stale text;
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then raise exception 'unknown reference' using errcode = 'P0002'; end if;
  if c.kind = 'card' then
    if c.status <> 'paid' then
      if p_cents is not null and p_cents <> c.amount * 100 then
        raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
      end if;
      update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;
      if p_card is not null and coalesce((p_card->>'reusable')::boolean, false) then
        update private.billing set card = p_card, card_email = (select email from auth.users where id = c.user_id),
               updated_at = now()
         where user_id = c.user_id;
      else
        update private.billing_charges set error = 'card not reusable: not saved' where reference = p_reference;
      end if;
    end if;
    return jsonb_build_object('status', 'paid', 'kind', 'card', 'refund', c.refunded_at is null,
      'saved', p_card is not null and coalesce((p_card->>'reusable')::boolean, false));
  end if;
  if c.status = 'paid' then return jsonb_build_object('status', 'paid', 'again', true, 'kind', c.kind); end if;
  if p_cents is not null and p_cents <> c.amount * 100 then
    raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
  end if;
  select * into b from private.billing where user_id = c.user_id for update;
  perform private.billing_lock(c.user_id);
  v_from := coalesce(b.plan, 'free');
  -- Paid, but the account has moved on since the charge was opened. Paystack has the
  -- money; nothing is applied. The error marks it for a refund from Paystack's dashboard.
  stale := private.billing_charge_stale(c, b);
  if stale is not null then
    update private.billing_charges set status = 'paid', settled_at = now(),
           error = 'refund: paid after the account changed (' || stale || '; ' || v_from || ', ' || coalesce(b.state, 'active') || ')'
     where reference = p_reference;
    raise warning 'billing charge % paid but not applied: refund it', p_reference;
    return jsonb_build_object('status', 'paid', 'applied', false, 'kind', c.kind);
  end if;
  update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;

  if c.kind = 'start' then
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
    values (c.user_id, c.plan, c.period, extract(day from today)::int,
            public.billing_step(today, c.period, extract(day from today)::int, 1))
    on conflict (user_id) do update
      set plan = excluded.plan, period = excluded.period, billing_day = excluded.billing_day,
          next_billing_date = excluded.next_billing_date, next_plan = null, next_period = null,
          state = 'active', past_due_since = null, updated_at = now();
  elsif c.kind = 'upgrade' then
    -- A new plan replaces a booked change; more plants on the same plan keep it.
    update private.billing
       set next_plan = case when plan = c.plan then next_plan end, plan = c.plan, updated_at = now()
     where user_id = c.user_id;
  else  -- renewal, settle
    update private.billing set state = 'active', past_due_since = null, updated_at = now() where user_id = c.user_id;
  end if;
  if c.kind in ('start', 'upgrade') then
    perform private.billing_resume(c.user_id, c.plants);
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
  return jsonb_build_object('status', 'paid', 'plan', b.plan, 'kind', c.kind);
end $$;

-- /billing/verify answers only the user who opened the charge.
create or replace function public.billing_charge_user(p_reference text)
returns uuid language sql stable security definer set search_path = public, private, pg_temp as $$
  select user_id from private.billing_charges where reference = p_reference
$$;
revoke all on function public.billing_charge_user(text) from public, anon, authenticated;
grant execute on function public.billing_charge_user(text) to service_role;

-- ---------------------------------------------------------------------------
-- 4. Free week
-- ---------------------------------------------------------------------------
-- The account's first link starts its week on any plan, so a paid account that moves
-- to Free is trimmed as Free (0111). 0121 recorded Free links only.
create or replace function public.billing_free_week_start(p_user uuid, p_sunsynk_username text)
returns void language sql security definer set search_path = public, private, pg_temp as $$
  insert into private.free_week_logins (sunsynk_username, user_id)
  values (lower(p_sunsynk_username), p_user)
  on conflict (user_id) do nothing
$$;

-- Paid accounts that linked before this: their week started with their first plant.
-- Comped accounts stay out (never trimmed, 0115).
insert into private.free_week_logins (sunsynk_username, user_id, started_at)
select distinct on (pu.user_id) coalesce(lower(a.sunsynk_username), ''), pu.user_id, pu.linked_at
  from public.plant_users pu
  join private.billing b on b.user_id = pu.user_id and not b.comped
  left join private.sunsynk_accounts a on a.id = pu.account_id
 order by pu.user_id, pu.linked_at
on conflict (user_id) do nothing;

do $$
declare f text;
begin
  foreach f in array array['billing_may_link(uuid, text, int[])', 'billing_extra_inverters(uuid, bigint[])',
                           'billing_book_change(uuid, text, text)', 'billing_renew(uuid)', 'billing_free_week_start(uuid, text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array['api_plant_start(bigint)', 'api_billing_keep(bigint)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
revoke all on function private.billing_to_free(uuid, date) from public, anon, authenticated;
