CREATE OR REPLACE FUNCTION billing.switch_interval(p_account uuid, p_interval text, p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  a billing.accounts;
  st billing.status;
  s billing.subscriptions;
  np billing.prices;
  plan text;
  nid uuid;
begin
  a := billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state <> 'active' or st.sub is null then raise exception 'no running plan' using errcode = '22023'; end if;
  if p_interval is null or p_interval not in ('month', 'year') then
    raise exception 'monthly or yearly' using errcode = '22023';
  end if;
  select * into s from billing.subscriptions where id = st.sub for update;
  -- a cancelled plan has no next billing date to switch
  if s.cancel_at_period_end then raise exception 'the plan is cancelled' using errcode = '22023'; end if;
  if s.period_end <= p_at then raise exception 'the renewal is due: pay it first' using errcode = '22023'; end if;
  if s.next_price is not null then select * into np from billing.prices where id = s.next_price; end if;
  plan := coalesce(np.plan, s.plan);
  if p_interval = s.interval and plan = s.plan and s.next_extra_places is null then
    nid := null;
  else
    nid := (billing.price_keeping_offer(plan, a.market, p_interval, s.offer, p_at)).id;
  end if;
  -- nothing changes (a repeat click): no write, no version bump, no event, as cancel does, so an
  -- open checkout stays good and the first change's email still goes
  if nid is not distinct from s.next_price then return billing.account_state(p_account, p_at); end if;
  update billing.subscriptions set next_price = nid, version = version + 1 where id = s.id;
  perform billing.bump(p_account);
  perform billing.log_event(p_account, p_at, p_actor, 'switch_interval',
                            jsonb_build_object('interval', s.interval, 'next_price', s.next_price),
                            jsonb_build_object('interval', p_interval, 'next_price', nid));
  return billing.account_state(p_account, p_at);
end $function$;
