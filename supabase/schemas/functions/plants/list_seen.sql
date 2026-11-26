CREATE OR REPLACE FUNCTION plants.list_seen(p_login uuid, p_plants jsonb, p_at timestamp with time zone DEFAULT now(), p_mode text DEFAULT 'sync'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  l plants.logins;
  listed jsonb;
  ids bigint[];
  old_live bigint[];
  gone bigint[] := '{}';
  back bigint[] := '{}';
  after_min int := coalesce((select c.value::int from public.app_config c where c.key = 'PLANT_GONE_AFTER_MIN'), 50);
  now_s bigint := extract(epoch from p_at)::bigint;
  g record;
  acc uuid;
begin
  if p_mode not in ('sync', 'relink') then raise exception 'list_seen: mode %', p_mode using errcode = '22023'; end if;
  perform pg_advisory_xact_lock_shared(3, 0);   -- waits for a billing run (SOLAR-438)
  perform pg_advisory_xact_lock(1, hashtext(p_login::text));
  select * into l from plants.logins where id = p_login;
  if not found or l.status = 'disabled' then return null; end if;
  if l.account is not null then perform billing.lock_account(l.account); end if;
  if l.kind = 'share' then
    -- only plants already ours (claimed ones have rows): no plant is made for an unclaimed share
    listed := coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'vendor_id', p.vendor_id, 'name', e->>'name'))
                          from jsonb_array_elements(coalesce(p_plants, '[]'::jsonb)) e
                          join plants.plants p on p.brand = l.brand and p.vendor_id = coalesce(e->>'vendor_id', e->>'id')), '[]'::jsonb);
  else
    listed := plants.list_ids(l.brand, p_plants);
  end if;
  ids := array(select (x->>'id')::bigint from jsonb_array_elements(listed) x order by 1);
  old_live := array(select lp.plant from plants.login_plants lp where lp.login = l.id and lp.gone_at is null order by 1);
  -- the share login: every account holding a claim on its plants, in id order, before the plants
  -- (billing.run's order: a released claim must not lock its account after a plant)
  if l.kind = 'share' then
    perform 1 from billing.accounts a
     where a.id in (select c.account from plants.claims c join plants.login_plants lp on lp.plant = c.plant
                     where lp.login = l.id and lp.gone_at is null)
     order by a.id for update;
  end if;
  perform billing.lock_plants(ids || old_live);

  if l.kind = 'login' then
    insert into plants.login_plants as lp (login, plant, plant_name, last_seen_at, linked_at)
    select l.id, (x->>'id')::bigint, x->>'name', p_at, p_at from jsonb_array_elements(listed) x
    on conflict (login, plant) do update set plant_name = coalesce(excluded.plant_name, lp.plant_name),
                                             last_seen_at = excluded.last_seen_at, gone_at = null, missing_since = null;
  else
    -- the share login: only claimed plants have rows (plants.claim makes them)
    update plants.login_plants lp set last_seen_at = p_at, missing_since = null
     where lp.login = l.id and lp.gone_at is null and lp.plant = any (ids);
  end if;
  back := array(select x from unnest(ids) x where x <> all (old_live)
                  and exists (select 1 from plants.login_plants lp where lp.login = l.id and lp.plant = x and lp.gone_at is null));

  if p_mode = 'relink' then
    with x as (update plants.login_plants lp set gone_at = p_at
                where lp.login = l.id and lp.gone_at is null and lp.plant <> all (ids) returning lp.plant)
    select coalesce(array_agg(plant order by plant), '{}') into gone from x;
  else
    with x as (update plants.login_plants lp set gone_at = p_at
                where lp.login = l.id and lp.gone_at is null and lp.plant <> all (ids)
                  and lp.missing_since <= p_at - make_interval(mins => after_min)
               returning lp.plant)
    select coalesce(array_agg(plant order by plant), '{}') into gone from x;
    update plants.login_plants lp set missing_since = p_at
     where lp.login = l.id and lp.gone_at is null and lp.plant <> all (ids) and lp.missing_since is null;
    for g in select lp.plant, lp.plant_name from plants.login_plants lp
              where lp.login = l.id and lp.plant = any (gone) order by lp.plant loop
      if l.kind = 'login' then
        insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
        values (l.user_id, g.plant, 'plant_off_login', 'plant_off_login:' || g.plant || ':' || now_s,
                jsonb_build_object('plants', jsonb_build_array(coalesce(g.plant_name, 'Plant ' || g.plant)), 'login', l.username), 1)
        on conflict do nothing;
      else
        -- a shared plant gone from the share list an hour: released, its owner told once
        for acc in select c.account from plants.claims c where c.plant = g.plant order by c.account loop
          insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
          select a.user_id, g.plant, 'share_removed', 'share_removed:' || g.plant || ':' || now_s,
                 jsonb_build_object('plants', jsonb_build_array(coalesce(g.plant_name, 'Plant ' || g.plant))), 1
            from billing.accounts a where a.id = acc
          on conflict do nothing;
          perform billing.lock_account(acc);
          delete from plants.claims c where c.account = acc and c.plant = g.plant;
          update billing.accounts set version = version + 1 where id = acc;
          perform billing.log_event(acc, p_at, 'share_gone', 'unclaim', null,
                                    jsonb_build_object('plants', jsonb_build_array(g.plant), 'closed', '[]'::jsonb));
        end loop;
      end if;
    end loop;
  end if;

  if cardinality(gone) + cardinality(back) > 0 then
    -- the plants' versions move (in-flight reads stop); the account's does not, so a plant
    -- new or gone on the login never refunds a checkout in progress
    perform plants.bump(gone || back);
    if l.account is not null then
      perform billing.log_event(l.account, p_at, 'poller', 'login_plants_seen',
                                jsonb_build_object('login', l.id, 'plants', to_jsonb(old_live)),
                                jsonb_build_object('gone', to_jsonb(gone), 'new', to_jsonb(back)));
    end if;
  end if;
  return jsonb_build_object('gone', to_jsonb(gone), 'new', to_jsonb(back), 'plants', listed);
end $function$;
