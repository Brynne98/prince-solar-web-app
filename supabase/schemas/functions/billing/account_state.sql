CREATE OR REPLACE FUNCTION billing.account_state(p_account uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  st billing.status;
  live boolean;
  next_retry timestamptz;
  fit text;
  plant_list jsonb;
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

  login_count := (select count(*) from plants.login_info l where l.account = p_account);

  select coalesce(jsonb_agg(jsonb_build_object(
           'plant', x.plant,
           'name', coalesce((select lp.plant_name from plants.list_info lp join plants.login_info l on l.id = lp.login
                              where l.account = p_account and lp.plant = x.plant and lp.plant_name is not null limit 1),
                            (select c.plant_name from plants.claim_info c where c.account = p_account and c.plant = x.plant),
                            -- a share removed (no claim left): the name it had
                            (select pu.plant_name from plants.user_plants pu where pu.user_id = (select ac.user_id from billing.accounts ac where ac.id = p_account)
                                and pu.plant_id = x.plant and pu.plant_name is not null limit 1),
                            (select lp.plant_name from plants.list_info lp join plants.login_info s on s.id = lp.login and s.kind = 'share'
                              where lp.plant = x.plant and lp.plant_name is not null limit 1)),
           'chosen', x.chosen,
           'locked', not x.chosen,
           'read_now', x.chosen and live and not st.must_choose and billing.has_route(p_account, x.plant, true)
                       and not (ps->>'deleting')::boolean,                                         -- 0277
           'needs_reconnect', billing.has_route(p_account, x.plant, false) and not billing.has_route(p_account, x.plant, true),
           'trial_used_elsewhere', pf.trial_used_at is not null and pf.trial_used_by is distinct from p_account,
           'delete_at', ps->'delete_at',
           'purged', ps->'purged',
           'deleting', ps->'deleting') order by x.plant), '[]'::jsonb)          -- 0277: deleting
    into plant_list
    from (select y.plant, exists (select 1 from billing.seats se where se.account = p_account and se.plant = y.plant
                                     and se.chosen_at <= p_at and (se.closed_at is null or se.closed_at > p_at)) as chosen
            from (select t.x from billing.linked_plants(p_account) t (x)
                  union
                  select se.plant from billing.seats se where se.account = p_account
                     and se.chosen_at <= p_at and (se.closed_at is null or se.closed_at > p_at)) y (plant)) x
    left join billing.plant_facts pf on pf.plant = x.plant
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
    'plants', plant_list) || billing.money_state(p_account, p_at, st.state) || billing.renewal_state(p_account, p_at, st);
end $function$;
