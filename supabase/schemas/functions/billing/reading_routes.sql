CREATE OR REPLACE FUNCTION billing.reading_routes(p_at timestamp with time zone)
 RETURNS TABLE(plant bigint, account uuid, lane uuid, via_share boolean, since timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'private', 'pg_temp'
AS $function$
  with seat as (
    select s.account, s.plant from billing.seats s
     where s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  ), live as (
    select x.account from (select distinct account from seat) x
     cross join lateral billing.account_status(x.account, p_at) st
     where st.state in ('trialing', 'active', 'past_due') and not st.must_choose
  )
  select se.plant, se.account, l.id, false, l.linked_at
    from seat se join live using (account)
    join plants.logins l on l.account = se.account and l.status = 'ok'
    join plants.login_plants lp on lp.login = l.id and lp.plant = se.plant and lp.gone_at is null
    join plants.logins sa on sa.id = l.id and sa.status = 'ok'
  union all
  select se.plant, se.account, sa.id, true, c.claimed_at
    from seat se join live using (account)
    join plants.claims c on c.plant = se.plant and c.account = se.account
    join plants.logins sa on sa.kind = 'share' and sa.status = 'ok' and sa.brand = plants.brand_of(c.plant)
$function$;
