CREATE OR REPLACE FUNCTION billing.accounts_live(p_accounts uuid[], p_at timestamp with time zone)
 RETURNS TABLE(account uuid, live boolean, must_choose boolean, ends_at timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  with a as (
    select a.id, a.trial_started_at, a.trial_ends_at, m.retry_days, m.trial_places,
           coalesce(a.time_zone, m.default_time_zone) as tz
      from billing.accounts a join billing.markets m on m.code = a.market
     where a.id = any (p_accounts)
  ), s as (
    select distinct on (s.account) s.*
      from billing.subscriptions s
     where s.account = any (p_accounts) and s.started_at <= p_at
     order by s.account, s.started_at desc
  ), nxt as (
    select s.account, min(s.started_at) as next_sub   -- a plan booked to start later
      from billing.subscriptions s
     where s.account = any (p_accounts) and s.started_at > p_at
     group by s.account
  ), g as (
    select g.account,
           coalesce(sum(g.places) filter (where g.starts_at <= p_at and (g.ends_at is null or g.ends_at > p_at)), 0) as places,
           min(g.ends_at) filter (where g.starts_at <= p_at and g.ends_at > p_at) as next_end
      from billing.grants g
     where g.account = any (p_accounts)
     group by g.account
  ), se as (
    select se.account,
           count(*) filter (where se.chosen_at <= p_at) as chosen,
           min(se.chosen_at) filter (where se.chosen_at > p_at) as next_seat   -- may put it over its places
      from billing.seats se
     where se.account = any (p_accounts) and (se.closed_at is null or se.closed_at > p_at)
     group by se.account
  ), x as (
    select a.*, s.id as sub, s.status, s.ended_at, s.cancel_at_period_end, s.period_end, s.extra_places, s.plan,
           case when s.status = 'past_due' then s.past_due_since end as pds,
           coalesce(g.places, 0) as grant_places, g.next_end as grant_end, coalesce(se.chosen, 0) as chosen, se.next_seat, nxt.next_sub
      from a
      left join s on s.account = a.id
      left join g on g.account = a.id
      left join se on se.account = a.id
      left join nxt on nxt.account = a.id
  ), y as (
    select x.*, billing.past_due_cutoff(x.pds, x.retry_days, x.tz) as cutoff from x
  ), z as (
    select y.*,
           case when y.sub is null then null
                when y.status = 'ended' then y.ended_at
                when y.cancel_at_period_end and y.period_end <= p_at then y.period_end
                -- a payment made before the cutoff and not answered yet keeps it running, at most a day
                when y.pds is not null and y.cutoff <= p_at
                     and not (select h.in_flight from billing.renewal_hold(y.id, p_at) h) then y.cutoff
           end as sub_end
      from y
  ), e as (
    select z.*,
           case when z.sub is null then null
                when z.sub_end is not null and z.sub_end <= p_at then 'ended'
                when z.pds is not null and z.pds <= p_at then 'past_due'
                else 'active' end as eff
      from z
  ), st as (
    select e.*,
           case when e.eff in ('active', 'past_due') then e.eff
                when e.grant_places > 0 then 'active'
                when e.trial_started_at <= p_at and p_at < e.trial_ends_at then 'trialing' end as state,
           coalesce(case when e.eff in ('active', 'past_due')
                           then (select p.places from billing.plans p where p.code = e.plan) + e.extra_places + e.grant_places
                         when e.grant_places > 0 then e.grant_places
                         when e.trial_started_at <= p_at and p_at < e.trial_ends_at then e.trial_places end, 0) as places
      from e
  )
  select st.id,
         st.state is not null,
         st.state is not null and st.chosen > st.places,
         case when st.state is not null then
           least(case when st.eff in ('active', 'past_due') then
                   least(case when st.status = 'ended' and st.ended_at > p_at then st.ended_at end,
                         case when st.cancel_at_period_end and st.period_end > p_at then st.period_end end,
                         case when st.pds is not null and st.cutoff > p_at then st.cutoff end,
                         -- held past the cutoff by a payment not answered yet: 24 hours at most (renewal_hold)
                         case when st.pds is not null and st.cutoff <= p_at then st.cutoff + interval '24 hours' end)
                 end,
                 case when st.state = 'trialing' then st.trial_ends_at end,
                 st.grant_end,
                 st.next_seat,
                 st.next_sub)
         end
    from st
$function$;
