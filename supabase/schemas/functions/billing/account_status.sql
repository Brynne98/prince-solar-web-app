CREATE OR REPLACE FUNCTION billing.account_status(p_account uuid, p_at timestamp with time zone)
 RETURNS billing.status
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
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
        and not exists (select 1 from billing.linked_plants(p_account) t (x) left join billing.plant_facts p on p.plant = t.x
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
end $function$;
