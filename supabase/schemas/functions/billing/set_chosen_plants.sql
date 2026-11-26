CREATE OR REPLACE FUNCTION billing.set_chosen_plants(p_account uuid, p_plants bigint[], p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  a billing.accounts;
  m billing.markets;
  st billing.status;
  want bigint[];
  had bigint[];
  bad bigint;
  next_places int;
  counted boolean;
begin
  a := billing.lock_account(p_account);
  select * into m from billing.markets where code = a.market;
  want := array(select distinct x from unnest(coalesce(p_plants, '{}')) x order by 1);
  had := array(select plant from billing.seats where account = p_account and closed_at is null order by 1);
  perform billing.lock_plants(want || had);
  st := billing.account_status(p_account, p_at);

  if st.state not in ('none', 'trialing', 'active') then
    raise exception 'plants cannot be chosen while the account is %', st.state using errcode = '22023';
  end if;
  -- a plant already chosen may stay chosen with no route (a share removed: kept, not read)
  select x into bad from unnest(want) x where not billing.has_route(p_account, x, false) and x <> all (had) limit 1;
  if found then
    raise exception 'plant % is not on this account''s logins', bad using errcode = '22023';
  end if;

  -- 0277: a plant switched back while its old history is still being deleted
  select x into bad from unnest(want) x where x <> all (had) and private.history_deleting(x) limit 1;
  if found then
    raise exception 'history of plant % is still being deleted', bad using errcode = '22023';
  end if;

  if st.state in ('none', 'trialing') then
    if cardinality(want) = 0 and st.state = 'none' then
      raise exception 'choose at least one plant to start the free week' using errcode = '22023';
    end if;
    select x into bad from unnest(want) x join billing.plants p on p.id = x
     where p.trial_used_at is not null and p.trial_used_by is distinct from p_account limit 1;
    if found then
      raise exception 'plant % already had its free week', bad using errcode = '22023';
    end if;
    if cardinality(want) > m.trial_places then
      raise exception 'the free week reads up to % plants', m.trial_places using errcode = '22023';
    end if;
    if st.state = 'none' then
      update billing.accounts set trial_started_at = p_at, trial_ends_at = p_at + make_interval(days => m.trial_days)
       where id = p_account;
    end if;
  elsif cardinality(want) > st.places then
    raise exception 'your plan has % places', st.places using errcode = '22023';
  else
    -- a booked downgrade: the plants not marked to drop must fit the next plan
    select coalesce(np.places, cp.places) + coalesce(sub.next_extra_places, sub.extra_places)
           + (st.places - cp.places - sub.extra_places)
      into next_places
      from billing.subscriptions sub
      join billing.plans cp on cp.code = sub.plan
      left join billing.prices pr on pr.id = sub.next_price
      left join billing.plans np on np.code = pr.plan
     where sub.id = st.sub and (sub.next_price is not null or sub.next_extra_places is not null);
    if next_places is not null and
       (select count(*) from unnest(want) x
         where not exists (select 1 from billing.seats se where se.account = p_account and se.plant = x
                              and se.closed_at is null and se.drop_at_period_end)) > next_places then
      raise exception 'your next plan has % places: pick the plants to drop first', next_places using errcode = '22023';
    end if;
  end if;

  -- the first choice after a login or a claim is linked is not a switch: its fetch never
  -- counts toward the slower history speed (0246 request_history)
  counted := exists (select 1 from billing.account_events e
                      where e.account = p_account and e.kind = 'set_chosen_plants'
                        and e.at > coalesce((select max(x.at) from billing.account_events x
                                              where x.account = p_account and x.kind in ('link_login', 'claim_plant')),
                                            '-infinity'));
  perform billing.write_seats(p_account, want, p_at, 'switched', counted);
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'set_chosen_plants',
                            jsonb_build_object('state', st.state, 'plants', to_jsonb(had)),
                            jsonb_build_object('plants', to_jsonb(want)));
  return billing.account_state(p_account, p_at);
end $function$;
