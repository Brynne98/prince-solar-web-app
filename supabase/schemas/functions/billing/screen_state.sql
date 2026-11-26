CREATE OR REPLACE FUNCTION billing.screen_state(p_account uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  s jsonb;
  a billing.accounts;
  m billing.markets;
  sub billing.subscriptions;
  last_sub billing.subscriptions;
  next_places int;
  prices jsonb;
  plant_list jsonb;
begin
  s := billing.account_state(p_account, p_at);
  if s is null then return null; end if;
  select * into a from billing.accounts where id = p_account;
  select * into m from billing.markets where code = a.market;
  if s->>'state' in ('active', 'past_due') then sub := billing.live_sub(p_account); end if;
  select * into last_sub from billing.subscriptions where account = p_account and started_at <= p_at
   order by started_at desc limit 1;
  if sub.id is not null then
    next_places := coalesce((select pl.places from billing.prices pr join billing.plans pl on pl.code = pr.plan
                              where pr.id = sub.next_price),
                            (select places from billing.plans where code = sub.plan))
                   + coalesce(sub.next_extra_places, sub.extra_places) + billing.grant_places(p_account, p_at);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'plan', pl.code, 'name', pl.name, 'places', pl.places, 'interval', iv.x,
           'amount_minor', pr.amount_minor, 'list_minor', lp.amount_minor, 'offer', pr.offer,
           'currency', m.currency) order by pl.places, iv.x), '[]'::jsonb)
    into prices
    from billing.plans pl cross join (values ('month'), ('year')) iv (x)
    cross join lateral billing.price_shown(p_account, pl.code, iv.x, p_at) pr
    cross join lateral billing.price_for(pl.code, a.market, iv.x, null, p_at) lp
   where pr.id is not null;

  -- each plant: what letting it go would do, and a booked drop
  select coalesce(jsonb_agg(p || jsonb_build_object(
           'kept_elsewhere', billing.kept_elsewhere(p_account, (p->>'plant')::bigint, p_at),
           -- a payment on its way: letting it go now keeps its history until that payment is answered
           'payment_hold', billing.payment_hold((p->>'plant')::bigint, p_at),
           'drop_at_period_end', coalesce((select se.drop_at_period_end from billing.seats se
                                             where se.account = p_account and se.plant = (p->>'plant')::bigint
                                               and se.closed_at is null), false),
           -- the logins that list it now, and the ones it went from (removing the last route deletes it)
           'logins', coalesce((select jsonb_agg(l.id order by l.linked_at) from plants.logins l
                                 join plants.login_plants lp on lp.login = l.id
                                where l.account = p_account and lp.plant = (p->>'plant')::bigint and lp.gone_at is null), '[]'::jsonb),
           'gone_logins', coalesce((select jsonb_agg(l.id order by l.linked_at) from plants.logins l
                                      join plants.login_plants lp on lp.login = l.id
                                     where l.account = p_account and lp.plant = (p->>'plant')::bigint and lp.gone_at is not null), '[]'::jsonb),
           'claimed', exists (select 1 from plants.claims c where c.account = p_account and c.plant = (p->>'plant')::bigint),
           -- it came through the share: removing the shared group lets it go (api_link_remove)
           'shared', exists (select 1 from plants.user_plants pu join plants.logins sa on sa.id = pu.account_id
                              where sa.kind = 'share' and pu.plant_id = (p->>'plant')::bigint
                                and pu.user_id = a.user_id))
         order by (p->>'plant')::bigint), '[]'::jsonb)
    into plant_list from jsonb_array_elements(s->'plants') p;

  return s || jsonb_build_object(
    'plants', plant_list,
    'at', p_at,                                  -- when this was read: dates before it have passed
    'time_zone', coalesce(a.time_zone, m.default_time_zone),
    'locale', a.locale,
    'plan_name', (select name from billing.plans where code = s->>'plan'),
    'next_plan_name', (select name from billing.plans where code = s->>'next_plan'),
    'next_places', next_places,
    'fit_all_name', (select name from billing.plans where code = s->>'fit_all_plan'),
    'last_plan', last_sub.plan,
    'last_plan_name', (select name from billing.plans where code = last_sub.plan),
    'had_plan', last_sub.id is not null,
    -- ended on a plan from us (a grant ended last), not on a paid plan or the free week
    'grant_ended', s->>'state' = 'ended' and exists (select 1 from billing.grants g where g.account = p_account
                      and g.ends_at = (s->>'access_ended_at')::timestamptz),
    'retention_days', m.retention_days,
    'trial_places', m.trial_places,
    -- the free week's last two days; a booked cancel's last three
    'trial_ends_soon', s->>'state' = 'trialing' and (s->>'trial_ends_at')::timestamptz - p_at <= interval '2 days',
    'cancel_soon', (s->>'cancel_at')::timestamptz - p_at <= interval '3 days',
    -- what a cancel (booked now, or already booked) means: this account's deadline, shown when
    -- it is the one that decides for a chosen plant, that is no other account would keep that
    -- plant's history longer on what is booked now. Null: no such plant.
    'if_cancelled_delete_at', case when sub.id is not null
                                    and exists (select 1 from jsonb_array_elements(plant_list) p
                                                 where (p->>'chosen')::boolean and not (p->>'purged')::boolean
                                                   and coalesce(billing.kept_by_others_until(p_account, (p->>'plant')::bigint, p_at),
                                                                '-infinity') <= sub.period_end + make_interval(days => m.retention_days))
                                   then sub.period_end + make_interval(days => m.retention_days) end,
    -- the earliest "kept until" among the chosen plant_list (null: nothing waits to be deleted)
    'history_kept_until', (select min((p->>'delete_at')::timestamptz) from jsonb_array_elements(plant_list) p
                            where (p->>'chosen')::boolean and (p->>'delete_at')::timestamptz > p_at),
    'history_purged', exists (select 1 from jsonb_array_elements(plant_list) p where (p->>'chosen')::boolean and (p->>'purged')::boolean),
    'prices', prices,
    'logins', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'brand', l.brand, 'username', l.username,
                          'status', l.status) order by l.linked_at)
                          from plants.logins l where l.account = p_account), '[]'::jsonb),
    'bills', coalesce((select jsonb_agg(b order by b->>'paid_at' desc) from (
                select jsonb_build_object('id', i.id, 'kind', i.kind, 'plan', i.plan,
                         'plan_name', i.plan_name, 'interval', i.interval,
                         'amount_minor', i.amount_minor, 'currency', i.currency, 'paid_at', i.paid_at,
                         'period_start', i.period_start, 'period_end', i.period_end,
                         'refunded', exists (select 1 from billing.payment_attempts pa join billing.refunds r on r.attempt = pa.id
                                              where pa.invoice = i.id and r.status = 'processed')) b
                  from billing.invoices i
                 where i.account = p_account and i.status = 'paid' and i.kind <> 'card_check' and i.amount_minor > 0
                 order by i.paid_at desc limit 6) x), '[]'::jsonb));
end $function$;
