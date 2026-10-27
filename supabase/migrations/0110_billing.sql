-- ============================================================================
-- 0110 — plans and billing rules, part 1 of SOLAR-208. No Paystack calls, no UI.
--
-- Plans: Free R0 (1 plant), Home R99/R999 (1 plant), Family R179/R1,799 (3 plants,
-- then R49 a month per inverter on each plant past the 3rd). Rules, all decided on
-- SOLAR-208 (ticket text and comments, 2026-10-27):
--   - Every plant counts, whatever login brought it (guard a). A plant is billed
--     per inverter on it whether it sends data or not.
--   - One free week per SunSynk login (guard b).
--   - Family covers the first 3 plants linked. Plants past those are the extras.
--   - Upgrade starts now and pays (new - old) x days left / days in period, rounded
--     to whole rand. Days left = billing date - today. The billing date stays.
--   - Downgrade, cancel (= downgrade to Free) and a monthly/yearly switch are booked
--     for the billing date. A downgrade can only be booked once the user is within
--     the new plan's plant limit: plants go first, then the plan.
--   - Removing a plant on a paid plan is booked for the billing date too. It is
--     billed until then, then deleted (purge_plant, run by the billing job).
--   - The bill falls on the same day of the month every period. In a shorter
--     month it falls on the last day, then goes back (31 Jan, 28 Feb, 31 Mar).
--
-- profiles.plan (free/pro) goes: private.billing replaces it. api_me reads the
-- plan from there, and profiles_guard has no plan left to guard.
--
-- Everything here is service_role only. The edge functions (link check, billing
-- job, Paystack webhook; later parts) call it.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table if not exists private.billing (
  user_id           uuid primary key references auth.users (id) on delete cascade,
  plan              text not null default 'free' check (plan in ('free', 'home', 'family')),
  period            text check (period in ('monthly', 'yearly')),
  -- the day of the month the bill falls on (the day of the first payment), and the
  -- next date it falls on
  billing_day       smallint check (billing_day between 1 and 31),
  next_billing_date date,
  -- Paystack authorization object and the email it was saved with (part 3)
  card              jsonb,
  card_email        text,
  state             text not null default 'active' check (state in ('active', 'past_due')),
  past_due_since    date,
  -- booked for next_billing_date: downgrade, cancel (next_plan 'free'), period switch
  next_plan         text check (next_plan in ('free', 'home', 'family')),
  next_period       text check (next_period in ('monthly', 'yearly')),
  -- plants deleted on remove_on: booked removals (remove_on = billing date), or the
  -- plants dropped after a failed payment (remove_on = 30 days after Free)
  plants_to_remove  bigint[] not null default '{}',
  remove_on         date,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint billing_paid_has_dates check (
    (plan = 'free') = (period is null and billing_day is null and next_billing_date is null)),
  constraint billing_free_books_nothing check (plan <> 'free' or (next_plan is null and next_period is null))
);
revoke all on table private.billing from public, anon, authenticated;
grant all on table private.billing to service_role;

-- Guard b. A login stays here after its plant or account is removed, so removing
-- and adding again never starts a second free week. No foreign key for that reason.
create table if not exists private.free_week_logins (
  sunsynk_username  text primary key,   -- lower case
  user_id           uuid not null,
  started_at        timestamptz not null default now()
);
revoke all on table private.free_week_logins from public, anon, authenticated;
grant all on table private.free_week_logins to service_role;

-- guard b looks logins up case-blind
create index if not exists sunsynk_accounts_username_lower_idx
  on private.sunsynk_accounts (lower(sunsynk_username));

-- ---------------------------------------------------------------------------
-- 2. profiles.plan goes
-- ---------------------------------------------------------------------------
create or replace function public.profiles_guard()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
alter table public.profiles drop column if exists plan;

create or replace function public.api_me()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'user', jsonb_build_object('id', auth.uid()),
    'plan', coalesce((select plan from private.billing where user_id = auth.uid()), 'free'),
    'prefs', coalesce((select prefs from public.profiles where user_id = auth.uid()), '{}'::jsonb),
    'plants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pu.plant_id, 'name', pu.plant_name, 'linkedAt', pu.linked_at,
               'config', to_jsonb(c) - 'plant_id' - 'updated_by')
             order by pu.linked_at, pu.plant_id)
        from public.plant_users pu
        left join public.plant_config c on c.plant_id = pu.plant_id
       where pu.user_id = auth.uid()), '[]'::jsonb))
$$;
revoke all on function public.api_me() from public, anon;
grant execute on function public.api_me() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Prices and dates (pure)
-- ---------------------------------------------------------------------------
-- Whole rand for one period. p_extra = inverters on plants past the 3rd (Family only).
-- Yearly extras are 12 x R49: the ticket prices them per month only.
create or replace function public.billing_amount(p_plan text, p_period text, p_extra int default 0)
returns int language sql immutable as $$
  select case p_plan
    when 'free'   then 0
    when 'home'   then case p_period when 'monthly' then 99  when 'yearly' then 999 end
    when 'family' then case p_period when 'monthly' then 179 when 'yearly' then 1799 end
                       + greatest(p_extra, 0) * case p_period when 'monthly' then 49 when 'yearly' then 588 end
  end
$$;

-- Plants a plan covers. Family has no cap; plants past 3 are billed per inverter.
create or replace function public.billing_plant_limit(p_plan text)
returns int language sql immutable as $$
  select case p_plan when 'family' then null else 1 end
$$;

-- The billing date p_steps periods from p_date, on p_day or the month's last day.
create or replace function public.billing_step(p_date date, p_period text, p_day int, p_steps int)
returns date language sql immutable as $$
  select (m + (least(p_day, extract(day from m + interval '1 month' - interval '1 day')::int) - 1)
              * interval '1 day')::date
    from (select date_trunc('month', p_date)
                 + p_steps * case p_period when 'yearly' then interval '1 year' else interval '1 month' end
                 as m) s
$$;

-- (difference) x days left / days in period, whole rand. Day 1 of the period pays
-- the whole difference; the last day pays one day's worth.
create or replace function public.billing_prorate(p_diff int, p_today date, p_period_start date, p_next date)
returns int language sql immutable as $$
  select case when p_diff <= 0 then 0
    else round(p_diff::numeric
               * (p_next - greatest(least(p_today, p_next), p_period_start))
               / (p_next - p_period_start))::int end
$$;

-- ---------------------------------------------------------------------------
-- 4. Rules for one user
-- ---------------------------------------------------------------------------
-- Inverters on the user's plants past the first 3 linked, leaving out p_skip.
create or replace function public.billing_extra_inverters(p_user uuid, p_skip bigint[] default '{}')
returns int language sql stable security definer set search_path = public, private, pg_temp as $$
  select count(*)::int
    from (select plant_id, row_number() over (order by linked_at, plant_id) as n
            from public.plant_users
           where user_id = p_user and plant_id <> all (p_skip)) p
    join private.inverters i on i.plant_id = p.plant_id
   where p.n > 3
$$;

-- The charge on the next billing date: booked changes and removals applied.
create or replace function public.billing_amount_due(p_user uuid)
returns int language sql stable security definer set search_path = public, private, pg_temp as $$
  select coalesce((
    select public.billing_amount(
             coalesce(b.next_plan, b.plan),
             coalesce(b.next_period, b.period),
             public.billing_extra_inverters(p_user,
               case when b.remove_on <= b.next_billing_date then b.plants_to_remove else '{}' end))
      from private.billing b
     where b.user_id = p_user and b.plan <> 'free' and coalesce(b.next_plan, b.plan) <> 'free'), 0)
$$;

-- What an upgrade costs now and what the next charge becomes. p_added = inverters
-- the upgrade adds past the 3rd plant (from billing_may_link). p_period is only
-- read on Free, where the first payment is the full price and starts the period.
create or replace function public.billing_upgrade_quote(
  p_user uuid, p_plan text, p_added int default 0, p_period text default null,
  p_today date default current_date)
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  extra int := public.billing_extra_inverters(p_user);
  old_amt int; new_amt int; nxt date;
begin
  select * into b from private.billing where user_id = p_user;
  if b.plan is null or b.plan = 'free' then
    if p_plan = 'free' or p_period is null then
      raise exception 'upgrade from Free needs a paid plan and a period' using errcode = '22023';
    end if;
    new_amt := public.billing_amount(p_plan, p_period, extra + p_added);
    nxt := public.billing_step(p_today, p_period, extract(day from p_today)::int, 1);
    return jsonb_build_object('dueNow', new_amt, 'nextCharge', new_amt, 'nextDate', nxt);
  end if;
  if (p_plan = 'home' and b.plan = 'family') or p_plan = 'free' then
    raise exception 'not an upgrade' using errcode = '22023';
  end if;
  old_amt := public.billing_amount(b.plan, b.period, extra);
  new_amt := public.billing_amount(p_plan, b.period, extra + p_added);
  return jsonb_build_object(
    'dueNow', public.billing_prorate(new_amt - old_amt, p_today,
                public.billing_step(b.next_billing_date, b.period, b.billing_day, -1),
                b.next_billing_date),
    'nextCharge', new_amt,
    'nextDate', b.next_billing_date);
end $$;

-- May this user link the plants one SunSynk login brings? p_plant_inverters holds
-- the inverter count of each new plant, in link order.
--   {ok: false, reason: 'free_week_used'}  guard b
--   {ok: false, reason: 'upgrade_needed', extraInverters}  over the Free or Home limit
--                                          (guard a); extraInverters prices the Family quote
--   {ok: true, extraInverters, dueNow}     on Family, the new inverters past plant 3
-- Plants booked for removal don't count: they are gone from the billing date.
create or replace function public.billing_may_link(p_user uuid, p_sunsynk_username text, p_plant_inverters int[])
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  v_plan text := coalesce((select b.plan from private.billing b where b.user_id = p_user), 'free');
  have int := (select count(*) from public.plant_users
                where user_id = p_user
                  and plant_id <> all (coalesce((select b.plants_to_remove from private.billing b
                                                  where b.user_id = p_user), '{}')));
  extra int;
begin
  if v_plan = 'free' and (
       exists (select 1 from private.free_week_logins
                where sunsynk_username = lower(p_sunsynk_username) and user_id <> p_user)
    or exists (select 1 from private.sunsynk_accounts
                where lower(sunsynk_username) = lower(p_sunsynk_username) and user_id <> p_user)) then
    return jsonb_build_object('ok', false, 'reason', 'free_week_used');
  end if;
  select coalesce(sum(n), 0) into extra
    from unnest(p_plant_inverters) with ordinality as t(n, i) where have + i > 3;
  if have + coalesce(cardinality(p_plant_inverters), 0) > coalesce(public.billing_plant_limit(v_plan), 2147483647) then
    return jsonb_build_object('ok', false, 'reason', 'upgrade_needed', 'extraInverters', extra);
  end if;
  return jsonb_build_object('ok', true, 'extraInverters', extra,
    'dueNow', case when v_plan = 'family' and extra > 0
                   then (public.billing_upgrade_quote(p_user, 'family', extra))->'dueNow' else '0' end);
end $$;

-- Book a downgrade, cancel (p_plan 'free') or period switch for the billing date.
-- Upgrades never come here: they start at once.
create or replace function public.billing_book_change(p_user uuid, p_plan text, p_period text default null)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  rank constant jsonb := '{"free": 0, "home": 1, "family": 2}';
  keep int;
begin
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' then
    raise exception 'nothing to change on Free' using errcode = '22023';
  end if;
  if (rank->>p_plan)::int > (rank->>b.plan)::int then
    raise exception 'an upgrade starts at once, not at the billing date' using errcode = '22023';
  end if;
  keep := (select count(*) from public.plant_users
            where user_id = p_user and plant_id <> all (b.plants_to_remove));
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

-- Book a plant for removal on the billing date. On Free, removal is at once (as today).
create or replace function public.billing_book_removal(p_user uuid, p_plant bigint)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  if not exists (select 1 from public.plant_users where user_id = p_user and plant_id = p_plant) then
    raise exception 'not your plant' using errcode = '42501';
  end if;
  update private.billing
     set plants_to_remove = array(select distinct x from unnest(plants_to_remove || p_plant) x order by x),
         remove_on = next_billing_date, updated_at = now()
   where user_id = p_user and plan <> 'free';
  if not found then
    raise exception 'removal on Free is at once' using errcode = '22023';
  end if;
end $$;

-- The billing date step: apply booked changes, move the date one period on, and
-- give the amount to charge and the plants to delete. The billing job charges and
-- purges; it clears plants_to_remove once they are gone.
create or replace function public.billing_renew(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  due int;
  v_plan text; v_period text;
begin
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' then
    raise exception 'nothing to renew on Free' using errcode = '22023';
  end if;
  due := public.billing_amount_due(p_user);
  v_plan := coalesce(b.next_plan, b.plan);
  v_period := coalesce(b.next_period, b.period);
  update private.billing
     set plan = v_plan,
         period = case when v_plan = 'free' then null else v_period end,
         billing_day = case when v_plan = 'free' then null else b.billing_day end,
         next_billing_date = case when v_plan = 'free' then null
                             else public.billing_step(b.next_billing_date, v_period, b.billing_day, 1) end,
         next_plan = null, next_period = null, updated_at = now()
   where user_id = p_user;
  return jsonb_build_object('charge', due, 'plan', v_plan,
    'removePlants', case when b.remove_on <= b.next_billing_date then to_jsonb(b.plants_to_remove)
                         else '[]'::jsonb end);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'billing_amount(text, text, int)', 'billing_plant_limit(text)',
    'billing_step(date, text, int, int)', 'billing_prorate(int, date, date, date)',
    'billing_extra_inverters(uuid, bigint[])', 'billing_amount_due(uuid)',
    'billing_upgrade_quote(uuid, text, int, text, date)', 'billing_may_link(uuid, text, int[])',
    'billing_book_change(uuid, text, text)', 'billing_book_removal(uuid, bigint)',
    'billing_renew(uuid)']
  loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
