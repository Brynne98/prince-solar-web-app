CREATE OR REPLACE FUNCTION billing.downgrade(p_account uuid, p_plan text, p_extra_places integer, p_drop bigint[], p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text, p_interval text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  a billing.accounts;
  st billing.status;
  s billing.subscriptions;
  pl billing.plans;
  pr billing.prices;
  np billing.prices;
  extras int;
  cur_places int;
  new_places int;
  drop_ids bigint[];
  bad bigint;
  iv text;
begin
  a := billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state <> 'active' or st.sub is null then raise exception 'no running plan' using errcode = '22023'; end if;
  if p_interval is not null and p_interval not in ('month', 'year') then
    raise exception 'monthly or yearly' using errcode = '22023';
  end if;
  select * into s from billing.subscriptions where id = st.sub for update;
  if s.cancel_at_period_end then raise exception 'the plan is cancelled' using errcode = '22023'; end if;
  if s.period_end <= p_at then raise exception 'the renewal is due: pay it first' using errcode = '22023'; end if;
  select * into pl from billing.plans where code = p_plan;
  if not found then raise exception 'no such plan' using errcode = '22023'; end if;
  extras := coalesce(p_extra_places, case when p_plan = s.plan then s.extra_places else 0 end);
  if extras < 0 or (extras > 0 and not pl.allows_extra) then
    raise exception 'extra places are not sold on %', pl.name using errcode = '22023';
  end if;
  cur_places := (select places from billing.plans where code = s.plan) + s.extra_places;
  new_places := pl.places + extras;
  if s.next_price is not null then select * into np from billing.prices where id = s.next_price; end if;
  iv := coalesce(p_interval, np.interval, s.interval);

  if p_plan = s.plan and extras = s.extra_places then
    -- undo: keep a booked interval switch only
    update billing.subscriptions
       set next_price = case when iv <> s.interval then (billing.price_keeping_offer(s.plan, a.market, iv, s.offer, p_at)).id end,
           next_extra_places = null, version = version + 1
     where id = s.id;
    update billing.seats set drop_at_period_end = false where account = p_account and closed_at is null;
  else
    if new_places >= cur_places then raise exception 'that is not fewer places' using errcode = '22023'; end if;
    drop_ids := array(select distinct x from unnest(coalesce(p_drop, '{}')) x order by 1);
    select x into bad from unnest(drop_ids) x
     where not exists (select 1 from billing.seats se where se.account = p_account and se.plant = x and se.closed_at is null)
     limit 1;
    if found then raise exception 'plant % is not chosen', bad using errcode = '22023'; end if;
    if st.chosen - cardinality(drop_ids) > new_places + billing.grant_places(p_account, p_at) then
      raise exception 'pick % more plants to drop', st.chosen - cardinality(drop_ids) - new_places - billing.grant_places(p_account, p_at)
        using errcode = '22023';
    end if;
    pr := billing.price_keeping_offer(p_plan, a.market, iv, s.offer, p_at);
    update billing.subscriptions set next_price = pr.id, next_extra_places = extras, version = version + 1 where id = s.id;
    update billing.seats set drop_at_period_end = (plant = any (drop_ids)) where account = p_account and closed_at is null;
  end if;
  perform billing.bump(p_account);
  perform billing.log_event(p_account, p_at, p_actor, 'downgrade',
                            jsonb_build_object('plan', s.plan, 'extras', s.extra_places),
                            jsonb_build_object('plan', p_plan, 'extras', extras, 'drop', to_jsonb(drop_ids), 'interval', iv));
  return billing.account_state(p_account, p_at);
end $function$;
