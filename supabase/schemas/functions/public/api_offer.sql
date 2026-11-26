CREATE OR REPLACE FUNCTION public.api_offer()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  m billing.markets := (select mk from billing.markets mk order by code limit 1);
  -- an account nobody has: what a new account is offered
  off text := billing.offer_for('00000000-0000-0000-0000-000000000000', now());
  o billing.offers := (select x from billing.offers x where x.code = off);
  list jsonb := '{}';
  at jsonb := '{}';
  iv text;
  r numeric;
begin
  for iv in select unnest(array['month', 'year']) loop
    list := list || jsonb_build_object(case iv when 'month' then 'monthly' else 'yearly' end, jsonb_build_object(
      'home', trim_scale((billing.price_for('home', m.code, iv, null, now())).amount_minor::numeric / 100),
      'family', trim_scale((billing.price_for('family', m.code, iv, null, now())).amount_minor::numeric / 100),
      'extra', trim_scale((billing.price_for('family', m.code, iv, null, now())).extra_place_minor::numeric / 100)));
    at := at || jsonb_build_object(case iv when 'month' then 'monthly' else 'yearly' end, jsonb_build_object(
      'home', trim_scale(coalesce((billing.price_for('home', m.code, iv, off, now())).amount_minor,
                                  (billing.price_for('home', m.code, iv, null, now())).amount_minor)::numeric / 100),
      'family', trim_scale(coalesce((billing.price_for('family', m.code, iv, off, now())).amount_minor,
                                    (billing.price_for('family', m.code, iv, null, now())).amount_minor)::numeric / 100),
      'extra', trim_scale(coalesce((billing.price_for('family', m.code, iv, off, now())).extra_place_minor,
                                   (billing.price_for('family', m.code, iv, null, now())).extra_place_minor)::numeric / 100)));
  end loop;
  return jsonb_build_object('prices', at, 'listPrices', list,
    'offer', case when off is not null then jsonb_build_object('id', o.code, 'months', null, 'cap', o.max_members,
               'joinsUntil', (o.valid_until at time zone m.default_time_zone)::date, 'held', false, 'until', null) end);
end $function$;
