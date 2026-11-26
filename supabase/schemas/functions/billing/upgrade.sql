CREATE OR REPLACE FUNCTION billing.upgrade(p_account uuid, p_plan text, p_extra_places integer, p_plants bigint[], p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text, p_interval text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  a billing.accounts;
  m billing.markets;
  st billing.status;
  s billing.subscriptions;
  pl billing.plans;
  pr billing.prices;
  extras int := coalesce(p_extra_places, 0);
  cur_places int;
  new_amt int;
  due int;
  want bigint[];
  inv billing.invoices;
  iv text;    -- the interval paid for now
  nxt text;   -- the interval from the billing date, when it changes then
begin
  a := billing.lock_account(p_account);
  select * into m from billing.markets where code = a.market;
  st := billing.account_status(p_account, p_at);
  if st.state = 'past_due' then raise exception 'pay the failed payment first' using errcode = '22023'; end if;
  if st.state <> 'active' or st.sub is null then raise exception 'no running plan' using errcode = '22023'; end if;
  if p_interval is not null and p_interval not in ('month', 'year') then
    raise exception 'monthly or yearly' using errcode = '22023';
  end if;
  select * into s from billing.subscriptions where id = st.sub for update;
  -- a cancelled plan buys nothing more: the screen offers Keep first
  if s.cancel_at_period_end then raise exception 'the plan is cancelled' using errcode = '22023'; end if;
  if s.period_end <= p_at then raise exception 'the renewal is due: pay it first' using errcode = '22023'; end if;
  select * into pl from billing.plans where code = p_plan;
  if not found then raise exception 'no such plan' using errcode = '22023'; end if;
  if extras < 0 or (extras > 0 and not pl.allows_extra) then
    raise exception 'extra places are not sold on %', pl.name using errcode = '22023';
  end if;
  cur_places := (select places from billing.plans where code = s.plan) + s.extra_places;
  if pl.places + extras <= cur_places then
    raise exception 'that is not more places' using errcode = '22023';
  end if;

  -- another plan monthly to yearly: the year now. Otherwise the plan's interval now, and a given
  -- interval from the billing date (it replaces a switch booked earlier)
  iv := case when p_interval = 'year' and s.interval = 'month' and p_plan <> s.plan then 'year' else s.interval end;
  nxt := case when iv = s.interval then p_interval end;
  pr := billing.price_keeping_offer(p_plan, a.market, iv, s.offer, p_at);
  new_amt := pr.amount_minor + extras * pr.extra_place_minor;
  due := billing.upgrade_due(s, m, new_amt, iv, p_at);
  want := billing.final_choice(p_account, p_plants, pl.places + extras + billing.grant_places(p_account, p_at));

  -- the same upgrade again (the card page closed, tried again): the same bill, while its sum is
  -- still today's (a day later the days left are fewer: a new bill at the new sum)
  select * into inv from billing.invoices
   where subscription = s.id and kind = 'upgrade' and status = 'open' and plan = p_plan and extra_places = extras
     and plants = want and expected_version = a.version and period_start = s.period_start
     and interval = iv and next_interval is not distinct from nxt and amount_minor = due
   order by created_at desc limit 1;
  if inv.id is not null then return billing.invoice_out(inv) || jsonb_build_object('applied', false); end if;
  if billing.payment_in_flight(p_account) then
    raise exception 'a payment is already in progress' using errcode = '22023';
  end if;
  perform billing.replace_card_pages(array(select id from billing.invoices
                                            where subscription = s.id and kind = 'upgrade' and status = 'open'), p_at);
  update billing.invoices set status = 'void' where subscription = s.id and kind = 'upgrade' and status = 'open';
  -- the bill names the period it is bought in; apply_upgrade moves it to the new year when the
  -- interval changes now
  insert into billing.invoices (account, subscription, kind, status, price, plan, interval, next_interval, offer, extra_places,
                                plan_amount_minor, extra_place_minor, amount_minor, tax_minor, currency, period_start,
                                period_end, period_key, expected_version, plants, created_at)
  values (p_account, s.id, 'upgrade', case when due < m.min_charge_minor then 'waived' else 'open' end, pr.id, p_plan,
          iv, nxt, s.offer, extras, pr.amount_minor, pr.extra_place_minor, due, pr.tax_minor, s.currency,
          s.period_start, s.period_end,
          extract(epoch from s.period_start)::bigint || ':' || p_plan || '+' || extras
            || case when iv <> s.interval then '@' || iv when nxt is not null then '>' || nxt else '' end,
          a.version, want, p_at)
  returning * into inv;
  perform billing.log_event(p_account, p_at, p_actor, 'upgrade',
                            jsonb_build_object('plan', s.plan, 'extras', s.extra_places, 'interval', s.interval),
                            jsonb_build_object('invoice', inv.id, 'plan', p_plan, 'extras', extras, 'due', due,
                                               'interval', iv, 'next_interval', nxt,
                                               'waived', inv.status = 'waived', 'plants', to_jsonb(want)));
  if inv.status = 'waived' then
    declare held boolean := billing.reading_held(p_account, p_at);              -- 0256
    begin
      perform billing.apply_upgrade(inv, p_at);
      if held and not billing.reading_held(p_account, p_at) then perform billing.readings_resume(p_account, p_at); end if;
    end;
    perform billing.bump(p_account);
    return billing.invoice_out(inv) || jsonb_build_object('applied', true);
  end if;
  return billing.invoice_out(inv) || jsonb_build_object('applied', false);
end $function$;
