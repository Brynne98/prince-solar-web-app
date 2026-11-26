CREATE OR REPLACE FUNCTION billing.quote(p_account uuid, p_plan text, p_interval text, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  a billing.accounts;
  m billing.markets;
  st billing.status;
  s billing.subscriptions;
  pl billing.plans;
  pr billing.prices;
  npr billing.prices;
  cur_places int;
  due int;
  iv text;
  nxt text;
begin
  select * into a from billing.accounts where id = p_account;
  select * into m from billing.markets where code = a.market;
  st := billing.account_status(p_account, p_at);
  select * into pl from billing.plans where code = p_plan;
  if not found then raise exception 'no such plan' using errcode = '22023'; end if;
  if st.sub is null then
    -- a first plan is monthly unless asked (api_plan_quote passes null through since 0279)
    p_interval := coalesce(p_interval, 'month');
    pr := billing.price_shown(p_account, p_plan, p_interval, p_at);
    return jsonb_build_object('kind', 'purchase', 'plan', p_plan, 'plan_name', pl.name, 'places', pl.places,
      'interval', p_interval, 'due_minor', pr.amount_minor, 'next_amount_minor', pr.amount_minor,
      'next_at', billing.add_period(p_at, p_interval, extract(day from p_at at time zone m.default_time_zone)::int, m.default_time_zone),
      'currency', m.currency, 'offer', pr.offer);
  end if;
  s := billing.live_sub(p_account);
  cur_places := (select places from billing.plans where code = s.plan) + s.extra_places;
  if pl.places > cur_places then
    iv := case when p_interval = 'year' and s.interval = 'month' and p_plan <> s.plan then 'year' else s.interval end;
    nxt := case when iv = s.interval then p_interval end;
    pr := billing.price_keeping_offer(p_plan, a.market, iv, s.offer, p_at);
    if nxt is not null then npr := billing.price_keeping_offer(p_plan, a.market, nxt, s.offer, p_at); end if;
    due := billing.upgrade_due(s, m, pr.amount_minor, iv, p_at);
    return jsonb_build_object('kind', 'upgrade', 'plan', p_plan, 'plan_name', pl.name, 'places', pl.places,
      'interval', coalesce(nxt, iv), 'starts_now', iv <> s.interval,
      'due_minor', case when due < m.min_charge_minor then 0 else due end,
      'next_amount_minor', coalesce(npr.amount_minor, pr.amount_minor),
      'next_at', case when iv <> s.interval
                      then billing.add_period(p_at, iv, extract(day from p_at at time zone m.default_time_zone)::int, m.default_time_zone)
                      else s.period_end end,
      'currency', s.currency, 'offer', pr.offer);
  end if;
  pr := billing.price_keeping_offer(p_plan, a.market, coalesce(p_interval, s.interval), s.offer, p_at);
  return jsonb_build_object('kind', case when pl.places < cur_places then 'downgrade' else 'interval' end,
    'plan', p_plan, 'plan_name', pl.name, 'places', pl.places, 'interval', pr.interval, 'due_minor', 0,
    'next_amount_minor', pr.amount_minor, 'next_at', s.period_end, 'currency', s.currency, 'offer', pr.offer,
    'drop', greatest(st.chosen - pl.places - billing.grant_places(p_account, p_at), 0));
end $function$;
