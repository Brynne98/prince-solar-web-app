CREATE OR REPLACE FUNCTION billing.start_checkout(p_account uuid, p_plan text, p_interval text, p_extra_places integer, p_plants bigint[], p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  a billing.accounts;
  m billing.markets;
  st billing.status;
  pl billing.plans;
  pr billing.prices;
  off text;
  extras int := coalesce(p_extra_places, 0);
  want bigint[];
  inv billing.invoices;
begin
  a := billing.lock_account(p_account);
  perform 1 from billing.offers order by code for update;      -- the last offer place goes to one checkout
  select * into m from billing.markets where code = a.market;
  st := billing.account_status(p_account, p_at);
  if st.sub is not null then raise exception 'a plan is already running' using errcode = '22023'; end if;
  -- a renewal paid before its plan ended may still be on its way: answered first (0248)
  if (select h.in_flight from billing.renewal_hold(p_account, p_at) h) then
    raise exception 'a payment is already in progress' using errcode = '22023';
  end if;
  select * into pl from billing.plans where code = p_plan;
  if not found then raise exception 'no such plan' using errcode = '22023'; end if;
  if p_interval is null or p_interval not in ('month', 'year') then
    raise exception 'monthly or yearly' using errcode = '22023';
  end if;
  if extras < 0 or (extras > 0 and not pl.allows_extra) then
    raise exception 'extra places are not sold on %', pl.name using errcode = '22023';
  end if;
  off := billing.offer_for(p_account, p_at);
  if off is not null then pr := billing.price_for(p_plan, a.market, p_interval, off, p_at); end if;
  if pr.id is null then
    off := null;
    pr := billing.price_for(p_plan, a.market, p_interval, null, p_at);
  end if;
  if pr.id is null then raise exception 'no price for % %', p_plan, p_interval using errcode = '22023'; end if;

  want := billing.final_choice(p_account, p_plants, pl.places + extras + billing.grant_places(p_account, p_at));
  -- one open purchase bill per account: the same checkout again gets the same bill; another
  -- one replaces it, unless a payment on it may still take money
  select * into inv from billing.invoices
   where account = p_account and kind = 'purchase' and status = 'open' order by created_at desc limit 1;
  if inv.id is not null then
    if inv.price = pr.id and inv.offer is not distinct from off and inv.extra_places = extras and inv.plants = want
       and inv.expected_version = a.version then
      return billing.invoice_out(inv);
    end if;
    if billing.payment_in_flight(p_account) then
      raise exception 'a payment is already in progress' using errcode = '22023';
    end if;
    perform billing.replace_card_pages(array(select id from billing.invoices
                                              where account = p_account and kind = 'purchase' and status = 'open'), p_at);
    update billing.invoices set status = 'void' where account = p_account and kind = 'purchase' and status = 'open';
  end if;
  insert into billing.invoices (account, kind, price, plan, interval, offer, extra_places, plan_amount_minor,
                                extra_place_minor, amount_minor, tax_minor, currency, expected_version, plants, created_at)
  values (p_account, 'purchase', pr.id, p_plan, p_interval, off, extras, pr.amount_minor, pr.extra_place_minor,
          pr.amount_minor + extras * pr.extra_place_minor, pr.tax_minor, m.currency, a.version, want, p_at)
  returning * into inv;
  perform billing.log_event(p_account, p_at, p_actor, 'start_checkout', jsonb_build_object('state', st.state),
                            jsonb_build_object('invoice', inv.id, 'plan', p_plan, 'interval', p_interval,
                                               'extras', extras, 'offer', off, 'plants', to_jsonb(want)));
  return billing.invoice_out(inv);
end $function$;
