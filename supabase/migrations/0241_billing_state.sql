-- ============================================================================
-- 0241 — billing redesign phase 1: account_state and plant_state (SOLAR-641).
--
-- The one place that works out an account's state and a plant's fate. Read-only.
-- Every function takes `at`, so tests can move the clock. The clock wins over
-- stored status: a booked cancel past its date, a renewal not paid by its date,
-- day 15 of a failed card and the end of the free week are all worked out here,
-- even if no job has run.
--
--   none      no trial started, no plan ever. (Every linked plant's week used
--             elsewhere: ended, so the pay screen shows.)
--   trialing  inside the free week.
--   active    a running plan, or a grant.
--   past_due  the job recorded a failed renewal try (status past_due,
--             past_due_since = that first try): retries on market.retry_days,
--             reading goes on; ends on day max(retry_days) + 1. A renewal due
--             but not yet tried stays active.
--   ended     the week or the plan is over.
--
-- protected = an open seat on a trialing/active/past_due account (login health
--             does not matter): its history is kept.
-- read_now  = protected, the account is not over its places (must_choose), and an
--             ok login (or a share claim) still reaches the plant.
-- delete_at = null while protected or already purged; else the latest
--             access_ended_at + retention_days over open seats on ended accounts
--             (null when no such end date is known); no open seat at all: `at`.
-- ============================================================================

-- Does the account still reach the plant? p_need_ok: only through an ok login or a claim.
create function billing.has_route(p_account uuid, p_plant bigint, p_need_ok boolean)
returns boolean language sql stable set search_path = billing, pg_temp as $$
  select exists (select 1 from billing.logins l join billing.login_plants lp on lp.login = l.id
                  where l.account = p_account and lp.plant = p_plant and lp.gone_at is null
                    and (not p_need_ok or l.status = 'ok'))
      or exists (select 1 from billing.plant_claims c where c.account = p_account and c.plant = p_plant)
$$;

-- Plants the account reaches now (any login health), plus plants it holds a seat on.
create function billing.linked_plants(p_account uuid)
returns setof bigint language sql stable set search_path = billing, pg_temp as $$
  select lp.plant from billing.logins l join billing.login_plants lp on lp.login = l.id
   where l.account = p_account and lp.gone_at is null
  union
  select c.plant from billing.plant_claims c where c.account = p_account
$$;

create type billing.status as (
  state           text,
  sub             uuid,
  plan            text,
  interval        text,
  amount_minor    int,
  currency        text,
  places          int,
  chosen          int,
  linked          int,
  must_choose     boolean,
  period_end      timestamptz,
  cancel_at       timestamptz,
  past_due_since  timestamptz,
  plan_ends_at    timestamptz,   -- a running plan's end: booked cancel date or the day after the last retry
  trial_ends_at   timestamptz,
  access_ended_at timestamptz,
  retention_days  int,
  retry_days      int[]
);

-- The core every other reader goes through. Null for an unknown account.
create function billing.account_status(p_account uuid, p_at timestamptz)
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
        r.plan_ends_at := pds + make_interval(days => (select max(d) from unnest(m.retry_days) d) + 1);
        if r.plan_ends_at <= p_at then sub_end := r.plan_ends_at; end if;
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

-- ---------------------------------------------------------------------------
-- plant_state: the poller asks read_now; the delete job asks delete_at.
-- ---------------------------------------------------------------------------
create function billing.plant_state(p_plant bigint, p_at timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = billing, pg_temp as $$
declare
  p billing.plants;
  se record;
  st billing.status;
  is_protected boolean := false;
  is_read boolean := false;
  latest timestamptz;
  seat_count int := 0;
  delete_at timestamptz;
begin
  select * into p from billing.plants where id = p_plant;
  if not found then return null; end if;
  for se in select s.account from billing.seats s
             where s.plant = p_plant and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  loop
    seat_count := seat_count + 1;
    st := billing.account_status(se.account, p_at);
    if st.state in ('trialing', 'active', 'past_due') then
      is_protected := true;
      if not st.must_choose and billing.has_route(se.account, p_plant, true) then is_read := true; end if;
    elsif st.state = 'ended' and st.access_ended_at is not null then
      latest := greatest(latest, st.access_ended_at + make_interval(days => st.retention_days));
    end if;
  end loop;
  delete_at := case when is_protected or p.history_purged_at is not null then null
                    when seat_count = 0 then p_at
                    else latest end;
  return jsonb_build_object(
    'plant', p_plant,
    'protected', is_protected,
    'read_now', is_read,
    'delete_at', delete_at,
    'purged', p.history_purged_at is not null,
    'open_seats', seat_count);
end $$;

-- Money facts for account_state (saved card, open bill, amount owed, may_delete).
-- Phase 1 has no payment tables: may_delete from the state alone. 0245 replaces it.
create function billing.money_state(p_account uuid, p_at timestamptz, p_state text)
returns jsonb language sql stable set search_path = billing, pg_temp as $$
  select jsonb_build_object('may_delete', p_state in ('none', 'trialing', 'ended'))
$$;

-- ---------------------------------------------------------------------------
-- account_state: everything a screen or email needs, nothing else works it out.
-- ---------------------------------------------------------------------------
create function billing.account_state(p_account uuid, p_at timestamptz default now())
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
                            (select c.plant_name from billing.plant_claims c where c.account = p_account and c.plant = x.plant)),
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
    'plants', plants) || billing.money_state(p_account, p_at, st.state);
end $$;

revoke all on function billing.has_route(uuid, bigint, boolean) from public, anon, authenticated;
revoke all on function billing.linked_plants(uuid) from public, anon, authenticated;
revoke all on function billing.account_status(uuid, timestamptz) from public, anon, authenticated;
revoke all on function billing.plant_state(bigint, timestamptz) from public, anon, authenticated;
revoke all on function billing.money_state(uuid, timestamptz, text) from public, anon, authenticated;
revoke all on function billing.account_state(uuid, timestamptz) from public, anon, authenticated;
grant execute on function billing.plant_state(bigint, timestamptz) to service_role;
grant execute on function billing.account_state(uuid, timestamptz) to service_role;
