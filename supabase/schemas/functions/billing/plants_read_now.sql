CREATE OR REPLACE FUNCTION billing.plants_read_now(p_plants bigint[], p_at timestamp with time zone)
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  with se as (
    select s.account, s.plant from billing.seats s
     where s.plant = any (p_plants) and not private.history_deleting(s.plant)   -- 0277
       and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  ), st as (
    select * from billing.accounts_live(array(select distinct account from se), p_at)
  )
  select distinct se.plant
    from se join st on st.account = se.account and st.live and not st.must_choose
   where exists (select 1 from plants.login_info l join plants.list_info lp on lp.login = l.id
                  where l.account = se.account and lp.plant = se.plant and lp.gone_at is null and l.status = 'ok')
      or exists (select 1 from plants.claim_info c where c.account = se.account and c.plant = se.plant)
$function$;
