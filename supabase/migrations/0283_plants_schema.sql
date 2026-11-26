-- SOLAR-681 (reports/rework-step-2-logins-plants-reading.md): one home for logins and plants.
--
-- Schema `plants`, owned by the Logins and plants part:
--   plants.brands        the brands we read (R15)
--   plants.plants        billing.plants moved here: our plant id, the brand's id (vendor_id, text),
--                        the plant's time zone (R26), the write fence (version)
--   plants.logins        billing.logins moved here, with private.sunsynk_accounts' columns: one row
--                        per login (R3); status words ok / needs_reconnect / disabled (R4)
--   plants.login_events  private.sunsynk_login_events moved here
--   plants.login_plants  billing.login_plants moved here, with plant_users' linked_at (R7)
--   plants.claims        billing.plant_claims moved here (share plants)
--   plants.user_plants   a view in plant_users' old shape, for readers (R2: read through plants.*)
-- Billing keeps billing.plant_facts: the trial and purge facts that were on billing.plants.
--
-- Our own plant id (R10-R11): the plants that exist keep their id (their history is keyed on
-- it). A new plant gets one from plants.plant_id_seq, from 1e12 up; only the rows moved here are
-- below that (legacy). plants.plant_for(brand, vendor_id) is the one way a plant is made.
--
-- One transaction: the moves, the copies, the compares (R25: each raises unless it finds 0
-- differences), the new function bodies and the drops. Writers wait on the table locks, so no
-- write lands between the copy and the switch.

create schema plants;
revoke all on schema plants from public, anon, authenticated;
grant usage on schema plants to service_role;

-- ---------------------------------------------------------------------------
-- brands
create table plants.brands (
  code         text primary key check (code ~ '^[a-z][a-z0-9_]*$'),
  display_name text not null,
  enabled      boolean not null default true
);
insert into plants.brands (code, display_name) values ('sunsynk', 'SunSynk'), ('mock', 'Test plants');

-- ---------------------------------------------------------------------------
-- plants
create function plants.tz_valid(p text) returns boolean
  language plpgsql immutable set search_path to '' as $$
begin
  if p is null or btrim(p) = '' then return false; end if;
  perform timestamp '2000-01-01' at time zone p;
  return true;
exception when others then return false;
end $$;

alter table billing.plants set schema plants;
alter table plants.plants rename column external_id to vendor_id;
alter table plants.plants rename constraint plants_brand_external_id_key to plants_brand_vendor_id_key;
alter table plants.plants
  add column time_zone text,
  add column legacy boolean not null default false,
  add column created_at timestamptz not null default now();

create table billing.plant_facts (
  plant             bigint primary key references plants.plants (id) on delete cascade,
  trial_used_at     timestamptz,
  trial_used_by     uuid references billing.accounts (id) on delete set null,
  history_purged_at timestamptz,
  check (trial_used_by is null or trial_used_at is not null)
);
alter table billing.plant_facts enable row level security;
revoke all on table billing.plant_facts from public, anon, authenticated;
insert into billing.plant_facts (plant, trial_used_at, trial_used_by, history_purged_at)
select id, trial_used_at, trial_used_by, history_purged_at from plants.plants
 where trial_used_at is not null or trial_used_by is not null or history_purged_at is not null;
do $$
begin
  if exists (select 1 from plants.plants p left join billing.plant_facts f on f.plant = p.id
              where (p.trial_used_at, p.trial_used_by, p.history_purged_at) is distinct from (f.trial_used_at, f.trial_used_by, f.history_purged_at)) then
    raise exception 'plant_facts: copy differs from billing.plants';
  end if;
end $$;
drop trigger plants_outbox on plants.plants;
alter table plants.plants drop constraint plants_check;
alter table plants.plants drop column trial_used_at, drop column trial_used_by, drop column history_purged_at;

-- each plant's zone: its own (plant_config, the brand's at link), else its market's default
update plants.plants p set time_zone = c.timezone
  from public.plant_config c where c.plant_id = p.id and c.timezone is not null;
update plants.plants p set time_zone = (select m.default_time_zone from billing.markets m order by m.code limit 1)
 where p.time_zone is null;
update plants.plants set legacy = true;
-- the zone lives on the plant now (R26); plant_config keeps the owner's settings
alter table public.plant_config drop column timezone;
alter table plants.plants
  alter column time_zone set not null,
  add constraint plants_time_zone_check check (plants.tz_valid(time_zone)),
  add constraint plants_brand_fkey foreign key (brand) references plants.brands (code),
  add constraint plants_own_id_check check (legacy = (id < 1000000000000));
create sequence plants.plant_id_seq start with 1000000000000 owned by plants.plants.id;
alter table plants.plants alter column id set default nextval('plants.plant_id_seq');

-- only this migration makes a legacy row (R10)
create function plants.plants_new_guard() returns trigger
  language plpgsql set search_path to '' as $$
begin
  if new.legacy or new.id < 1000000000000 then
    raise exception 'plants: a new plant takes an id from plants.plant_id_seq (got %)', new.id;
  end if;
  return new;
end $$;
create trigger plants_new_guard before insert on plants.plants for each row execute function plants.plants_new_guard();

-- ---------------------------------------------------------------------------
-- logins: billing.logins moved, private.sunsynk_accounts folded in
alter table billing.logins set schema plants;
alter table plants.logins drop constraint logins_status_check;
alter table plants.logins rename column created_at to linked_at;
alter table plants.logins
  alter column account drop not null,
  add column user_id uuid references auth.users (id) on delete cascade,
  add column kind text not null default 'login' check (kind in ('login', 'share')),
  add column refresh_secret_id uuid,
  add column access_token text,
  add column access_expires_at bigint,
  add column last_ok_at timestamptz,
  add column last_error text,
  add column last_try_at timestamptz,
  add column last_try text check (last_try in ('ok', 'sunsynk', 'ours'));

-- the share login has no billing account: its row comes over too
insert into plants.logins (id, account, brand, username, secret_ref, status, linked_at, kind)
select sa.id, null, sa.provider, sa.sunsynk_username, sa.refresh_secret_id, 'ok', sa.linked_at, sa.kind
  from private.sunsynk_accounts sa
 where not exists (select 1 from plants.logins l where l.id = sa.id);
update plants.logins l
   set user_id = sa.user_id, kind = sa.kind, refresh_secret_id = sa.refresh_secret_id,
       access_token = sa.access_token, access_expires_at = sa.access_expires_at,
       last_ok_at = sa.last_ok_at, last_error = sa.last_error, last_try_at = sa.last_try_at, last_try = sa.last_try,
       username = sa.sunsynk_username, linked_at = sa.linked_at,
       status = case sa.status when 'active' then 'ok' when 'needs_relink' then 'needs_reconnect' else sa.status end
  from private.sunsynk_accounts sa where sa.id = l.id;
-- a login billing never knew (none in production on 2026-11-26) is a row with no account
do $$
begin
  if exists (select 1 from private.sunsynk_accounts sa full join plants.logins l on l.id = sa.id
              where l.id is null or sa.id is null
                 or (l.user_id, l.kind, l.username, l.refresh_secret_id, l.access_token, l.access_expires_at,
                     l.last_ok_at, l.last_error, l.last_try_at, l.last_try, l.linked_at)
                    is distinct from
                    (sa.user_id, sa.kind, sa.sunsynk_username, sa.refresh_secret_id, sa.access_token, sa.access_expires_at,
                     sa.last_ok_at, sa.last_error, sa.last_try_at, sa.last_try, sa.linked_at)
                 or l.status <> case sa.status when 'active' then 'ok' when 'needs_relink' then 'needs_reconnect' else sa.status end) then
    raise exception 'plants.logins: copy differs from private.sunsynk_accounts';
  end if;
  if exists (select 1 from plants.logins l join billing.accounts a on a.id = l.account where a.user_id <> l.user_id) then
    raise exception 'plants.logins: account and user disagree';
  end if;
end $$;
alter table plants.logins drop column secret_ref;
alter table plants.logins
  alter column user_id set not null,
  add constraint logins_status_check check (status in ('ok', 'needs_reconnect', 'disabled')),
  add constraint logins_account_check check (account is not null or kind = 'share'),
  add constraint logins_brand_fkey foreign key (brand) references plants.brands (code);
create unique index logins_one_share on plants.logins (brand) where kind = 'share';
create unique index logins_user_username on plants.logins (user_id, lower(username), brand);

alter table private.sunsynk_login_events set schema plants;
alter table plants.sunsynk_login_events rename to login_events;
alter table plants.login_events drop constraint sunsynk_login_events_account_id_fkey,
  add constraint login_events_account_id_fkey foreign key (account_id) references plants.logins (id) on delete cascade;

alter table private.inverters drop constraint inverters_account_id_fkey,
  add constraint inverters_account_id_fkey foreign key (account_id) references plants.logins (id) on delete set null;

-- ---------------------------------------------------------------------------
-- plant lists: billing.login_plants moved, plant_users folded in; claims moved
alter table billing.login_plants set schema plants;
alter table plants.login_plants add column linked_at timestamptz not null default now();
update plants.login_plants lp set linked_at = pu.linked_at
  from public.plant_users pu where pu.account_id = lp.login and pu.plant_id = lp.plant and not pu.via_share;
alter table billing.plant_claims set schema plants;
alter table plants.plant_claims rename to claims;
do $$
begin
  -- own-login rows: the same set, names and gone flags (R7)
  if exists (select 1 from public.plant_users pu
               full join plants.login_plants lp on lp.login = pu.account_id and lp.plant = pu.plant_id
              where coalesce(pu.via_share, false) = false
                and (pu.plant_id is null or lp.plant is null or pu.plant_name is distinct from lp.plant_name
                     or (pu.share_gone_at is null) <> (lp.gone_at is null))) then
    raise exception 'plants.login_plants: differs from plant_users';
  end if;
  if exists (select 1 from public.plant_users pu where pu.via_share and pu.share_gone_at is null
              and not exists (select 1 from plants.claims c join billing.accounts a on a.id = c.account
                               where c.plant = pu.plant_id and a.user_id = pu.user_id)) then
    raise exception 'plants.claims: a share row of plant_users has no claim';
  end if;
end $$;

-- the share login's list: the claimed plants it shows (was plant_users' via_share rows)
insert into plants.login_plants (login, plant, plant_name, linked_at, last_seen_at, missing_since, gone_at)
select pu.account_id, pu.plant_id, pu.plant_name, pu.linked_at, now(), pu.share_missing_at, pu.share_gone_at
  from public.plant_users pu where pu.via_share and pu.account_id is not null
on conflict (login, plant) do nothing;

-- plant_users' shape, for the readers (R2); writes go to login_plants and claims
create view plants.user_plants with (security_barrier) as
  -- one row per user and plant, as plant_users had (its key): a live row before a gone one,
  -- an own login before a share
  select distinct on (u.plant_id, u.user_id) u.*
    from (select lp.plant as plant_id, l.user_id, l.id as account_id, lp.plant_name, lp.linked_at,
                 false as via_share, lp.missing_since as share_missing_at, lp.gone_at as share_gone_at
            from plants.login_plants lp join plants.logins l on l.id = lp.login
           where l.kind = 'login'
          union all
          select c.plant, a.user_id, s.id, c.plant_name, c.claimed_at, true, sl.missing_since, sl.gone_at
            from plants.claims c
            join billing.accounts a on a.id = c.account
            join plants.logins s on s.kind = 'share' and s.brand = (select p.brand from plants.plants p where p.id = c.plant)
            left join plants.login_plants sl on sl.login = s.id and sl.plant = c.plant) u
   order by u.plant_id, u.user_id, u.share_gone_at is not null, u.via_share, u.linked_at, u.account_id;
revoke all on plants.user_plants from public, anon, authenticated;

-- every table in schema plants: no browser access
do $$
declare t text;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'plants' and c.relkind in ('r', 'p') loop
    execute format('alter table plants.%I enable row level security', t);
    execute format('revoke all on table plants.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- the plants part's functions

alter table plants.brands add column is_default boolean not null default false;
update plants.brands set is_default = true where code = 'sunsynk';
create unique index brands_one_default on plants.brands (is_default) where is_default;

-- the brand of a login made before logins had one, and of a link that names none
create function plants.default_brand() returns text
  language sql stable set search_path to '' as $$
  select b.code from plants.brands b where b.is_default
$$;

-- the brand a login belongs to by its username (the link and the share login use it)
create function plants.brand_for_username(p_username text) returns text
  language sql stable set search_path to '' as $$
  select case when lower(p_username) like '%@mock' then 'mock' else plants.default_brand() end
$$;
revoke all on function plants.brand_for_username(text) from public, anon, authenticated;


-- R11: the one way a plant is found or made from the brand's own id
create function plants.plant_for(p_brand text, p_vendor_id text) returns bigint
  language plpgsql security definer set search_path to '' as $$
declare id bigint;
begin
  if p_vendor_id is null or btrim(p_vendor_id) = '' then raise exception 'plant_for: no vendor id' using errcode = '22023'; end if;
  select p.id into id from plants.plants p where p.brand = p_brand and p.vendor_id = p_vendor_id;
  if found then return id; end if;
  insert into plants.plants (brand, vendor_id, time_zone)
  values (p_brand, p_vendor_id, (select m.default_time_zone from billing.markets m order by m.code limit 1))
  on conflict (brand, vendor_id) do nothing
  returning plants.plants.id into id;
  if id is null then   -- a concurrent call made it first
    select p.id into id from plants.plants p where p.brand = p_brand and p.vendor_id = p_vendor_id;
  end if;
  return id;
end $$;

-- a plant's brand
create function plants.brand_of(p_plant bigint) returns text
  language sql stable security definer set search_path to '' as $$
  select p.brand from plants.plants p where p.id = p_plant
$$;

-- the write fence: a read or write that started on an older version is refused (0246)
create function plants.bump(p_plants bigint[]) returns void
  language sql security definer set search_path to '' as $$
  -- locks in id order first, as billing.lock_plants does: never a deadlock with a save (R19)
  select null from (select p.id from plants.plants p where p.id = any (coalesce(p_plants, '{}')) order by p.id for update) x;
  update plants.plants set version = version + 1 where id = any (coalesce(p_plants, '{}'))
$$;

-- our ids for a list as the brand gives it: [{vendor_id or id, name}] -> [{id, vendor_id, name}]
create function plants.list_ids(p_brand text, p_plants jsonb) returns jsonb
  language sql security definer set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', plants.plant_for(p_brand, v), 'vendor_id', v, 'name', e->>'name')
                            order by v), '[]'::jsonb)
    from (select distinct on (coalesce(e->>'vendor_id', e->>'id')) coalesce(e->>'vendor_id', e->>'id') v, e
            from jsonb_array_elements(coalesce(p_plants, '[]'::jsonb)) e
           where coalesce(e->>'vendor_id', e->>'id') is not null) x
$$;

-- R7: which plants this user's logins and claims list (membership, not access: my_plant_ids is access)
create function plants.user_plant_ids(p_user uuid) returns setof bigint
  language sql stable security definer set search_path to '' as $$
  select distinct u.plant_id from plants.user_plants u where u.user_id = p_user and u.share_gone_at is null
$$;

-- R8: the one writer of a login's list. The whole list, as the brand gave it.
--   sync:   a plant missing 50 minutes (plants.gone_after_min) is gone; one mail per plant on an
--           own login; on the share login only claimed plants are tracked, and a gone one is
--           released and its owner mailed.
--   relink: the owner signed in again: a plant not in the fresh list is gone at once, no mail.
-- Locks: the login, then its account, then the plants (R19).
create function plants.list_seen(p_login uuid, p_plants jsonb, p_at timestamptz default now(), p_mode text default 'sync')
  returns jsonb language plpgsql security definer set search_path to '' as $$
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
end $$;

-- R5: may this user add this login, or reconnect it (an existing username always may)
create function plants.link_allowed(p_user uuid, p_brand text, p_username text) returns boolean
  language sql stable security definer set search_path to '' as $$
  select coalesce((select (billing.account_state(a.id)->>'may_add_login')::boolean
                          or exists (select 1 from plants.logins l where l.account = a.id and l.brand = p_brand
                                        and lower(l.username) = lower(p_username))
                     from billing.accounts a where a.user_id = p_user), true)
$$;

-- A login linked (or linked again) by its owner: the row, its token, its plant list (relink
-- mode), in one transaction. Returns the login id. Refused (22023) when the account may not add
-- it: the check runs here again, under the account lock (R5).
create function plants.link_login(p_account uuid, p_brand text, p_username text, p_plants jsonb,
    p_at timestamptz default now(), p_actor text default 'owner', p_id uuid default null,
    p_access text default null, p_expires bigint default null)
  returns uuid language plpgsql security definer set search_path to '' as $$
declare
  st billing.status;
  l plants.logins;
  uid uuid := (select a.user_id from billing.accounts a where a.id = p_account);
  is_new boolean;
  seen jsonb;
begin
  -- the same login whatever the case of its email (the brand ignores it)
  select * into l from plants.logins x
   where x.account = p_account and x.brand = p_brand and lower(x.username) = lower(p_username)
   order by x.username = p_username desc, x.id limit 1;
  if l.id is not null then perform pg_advisory_xact_lock(1, hashtext(l.id::text)); end if;
  perform billing.lock_account(p_account);
  -- read again under the locks: a remove or another link may have finished while this waited
  select * into l from plants.logins x
   where x.account = p_account and x.brand = p_brand and lower(x.username) = lower(p_username)
   order by x.username = p_username desc, x.id limit 1;
  is_new := l.id is null;
  st := billing.account_status(p_account, p_at);
  if is_new then
    if st.state = 'ended' then
      raise exception 'no login can be added without a plan' using errcode = '22023';
    end if;
    if st.state in ('none', 'trialing') and exists (select 1 from plants.logins x where x.account = p_account) then
      raise exception 'one login during the free week' using errcode = '22023';
    end if;
    insert into plants.logins (id, account, user_id, brand, kind, username, status, linked_at,
                               access_token, access_expires_at, last_ok_at)
    values (coalesce(p_id, gen_random_uuid()), p_account, uid, p_brand, 'login', p_username, 'ok', p_at,
            p_access, p_expires, case when p_access is not null then p_at end)
    returning * into l;
  else
    -- before the update wipes status and last_error
    insert into plants.login_events (account_id, event, reason, last_ok_at, access_expires_at)
    values (l.id, 'relinked', l.status || coalesce(': ' || l.last_error, ''), l.last_ok_at, l.access_expires_at);
    update plants.logins x set status = 'ok', last_error = null,
           access_token = coalesce(p_access, x.access_token), access_expires_at = coalesce(p_expires, x.access_expires_at),
           last_ok_at = case when p_access is not null then p_at else x.last_ok_at end
     where x.id = l.id returning * into l;
  end if;
  seen := plants.list_seen(l.id, p_plants, p_at, 'relink');
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, case when is_new then 'link_login' else 'relink_login' end,
                            jsonb_build_object('state', st.state),
                            jsonb_build_object('login', l.id, 'plants', seen->'plants'));
  return l.id;
end $$;

-- a plant shared to the share login, claimed by an account (by the brand's id, R11)
create function plants.claim(p_account uuid, p_brand text, p_vendor_id text, p_name text,
    p_at timestamptz default now(), p_actor text default 'owner')
  returns bigint language plpgsql security definer set search_path to '' as $$
declare
  st billing.status;
  holder uuid;
  pid bigint;
  share uuid := (select s.id from plants.logins s where s.kind = 'share' and s.brand = p_brand);
begin
  if share is null then raise exception 'claim: no share login for %', p_brand; end if;
  perform pg_advisory_xact_lock(1, hashtext(share::text));
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  pid := plants.plant_for(p_brand, p_vendor_id);
  perform billing.lock_plants(array[pid]);
  select c.account into holder from plants.claims c where c.plant = pid;
  if holder is not null and holder <> p_account then raise exception 'taken' using errcode = '22023'; end if;
  insert into plants.login_plants as lp (login, plant, plant_name, last_seen_at, linked_at)
  values (share, pid, p_name, p_at, p_at)
  on conflict (login, plant) do update set gone_at = null, missing_since = null, last_seen_at = excluded.last_seen_at,
                                           plant_name = coalesce(excluded.plant_name, lp.plant_name);
  if holder is not null then
    update plants.claims set plant_name = coalesce(p_name, plant_name) where plant = pid;
    return pid;
  end if;
  if st.state = 'ended' and not billing.has_route(p_account, pid, false) then
    raise exception 'no plant can be added without a plan' using errcode = '22023';
  end if;
  insert into plants.claims (plant, account, claimed_at, plant_name) values (pid, p_account, p_at, p_name);
  perform plants.bump(array[pid]);
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'claim_plant', jsonb_build_object('state', st.state),
                            jsonb_build_object('plant', pid, 'name', p_name));
  return pid;
end $$;

create function plants.unclaim(p_account uuid, p_plants bigint[], p_at timestamptz default now(), p_actor text default 'owner')
  returns jsonb language plpgsql security definer set search_path to '' as $$
declare closed bigint[];
begin
  perform pg_advisory_xact_lock_shared(3, 0);   -- waits for a billing run (SOLAR-438)
  perform billing.lock_account(p_account);
  perform billing.lock_plants(p_plants);
  delete from plants.claims where account = p_account and plant = any (p_plants);
  with c as (
    update billing.seats set closed_at = p_at, close_reason = 'login_removed'
     where account = p_account and closed_at is null and plant = any (p_plants)
       and not billing.has_route(p_account, plant, false)
    returning plant)
  select coalesce(array_agg(plant order by plant), '{}') into closed from c;
  perform plants.bump(p_plants);
  perform billing.purge_now(x, p_at) from unnest(closed) x;
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'unclaim', null,
                            jsonb_build_object('plants', to_jsonb(p_plants), 'closed', to_jsonb(closed)));
  return billing.account_state(p_account, p_at);
end $$;

-- the owner removes a login: its row, its secret, its list; seats it alone reached close
create function plants.remove_login(p_account uuid, p_login uuid, p_at timestamptz default now(), p_actor text default 'owner')
  returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  st billing.status;
  reached bigint[];
  closed bigint[];
  unprotected bigint[];
  v_secret uuid;
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  perform pg_advisory_xact_lock(1, hashtext(p_login::text));
  perform billing.lock_account(p_account);
  select l.refresh_secret_id into v_secret from plants.logins l where l.id = p_login and l.account = p_account;
  if not found then raise exception 'no such login on this account' using errcode = 'P0002'; end if;
  st := billing.account_status(p_account, p_at);
  reached := array(select plant from plants.login_plants where login = p_login order by 1);
  perform billing.lock_plants(reached);

  delete from plants.logins where id = p_login;   -- its list and events go with it
  if v_secret is not null and not exists (select 1 from plants.logins o where o.refresh_secret_id = v_secret) then
    delete from vault.secrets s where s.id = v_secret;
  end if;
  with c as (
    update billing.seats set closed_at = p_at, close_reason = 'login_removed'
     where account = p_account and closed_at is null and plant = any (reached)
       and not billing.has_route(p_account, plant, false)
    returning plant)
  select coalesce(array_agg(plant order by plant), '{}') into closed from c;
  perform plants.bump(closed);
  unprotected := array(select x from unnest(closed) x
                        where not (billing.plant_state(x, p_at)->>'protected')::boolean);
  perform billing.purge_now(x, p_at) from unnest(closed) x;
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'remove_login',
                            jsonb_build_object('state', st.state, 'login', p_login, 'plants', to_jsonb(reached)),
                            jsonb_build_object('closed', to_jsonb(closed), 'unprotected', to_jsonb(unprotected)));
  return billing.account_state(p_account, p_at) || jsonb_build_object('unprotected', to_jsonb(unprotected));
end $$;

-- a login's status moved (R3: was billing.login_status_follow): reads of its plants stop
create function plants.login_status_changed() returns trigger
  language plpgsql security definer set search_path to '' as $$
begin
  if new.status is not distinct from old.status then return null; end if;
  perform plants.bump(array(select lp.plant from plants.login_plants lp where lp.login = new.id));
  if new.account is not null then
    perform billing.log_event(new.account, now(), 'poller', 'login_status',
                              jsonb_build_object('login', new.id, 'status', old.status),
                              jsonb_build_object('login', new.id, 'status', new.status));
  end if;
  return null;
end $$;
create trigger logins_status_changed after update of status on plants.logins
  for each row execute function plants.login_status_changed();
create trigger email_on_relink after update of status on plants.logins
  for each row execute function private.email_on_relink();

-- a plant new on a list whose history is already in: the history mail (was on plant_users)
create function plants.plant_listed() returns trigger
  language plpgsql security definer set search_path to '' as $$
declare uid uuid;
begin
  if tg_table_name = 'claims' then
    uid := (select a.user_id from billing.accounts a where a.id = new.account);
  else
    uid := (select l.user_id from plants.logins l where l.id = new.login and l.kind = 'login');
  end if;
  if uid is not null and exists (select 1 from public.plant_config c where c.plant_id = new.plant and private.history_done(c)) then
    insert into public.email_queue (user_id, plant_id, kind, key, priority)
    values (uid, new.plant, 'history', 'history:' || new.plant, 1)
    on conflict do nothing;
  end if;
  return null;
end $$;
create trigger plant_listed after insert on plants.login_plants for each row execute function plants.plant_listed();
create trigger plant_listed after insert on plants.claims for each row execute function plants.plant_listed();

create trigger plants_outbox after update of history_purged_at on billing.plant_facts
  for each row execute function billing.outbox_on_purge();
create trigger plants_outbox_insert after insert on billing.plant_facts
  for each row when (new.history_purged_at is not null) execute function billing.outbox_on_purge();

-- the edge's door to list_seen (PostgREST reaches public only): the plant sync and share check
create function public.plants_list_seen(p_login uuid, p_plants jsonb, p_mode text default 'sync') returns jsonb
  language sql security definer set search_path to '' as $$
  select plants.list_seen(p_login, p_plants, now(), p_mode)
$$;
revoke all on function public.plants_list_seen(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.plants_list_seen(uuid, jsonb, text) to service_role;

-- our ids for the brand's plant ids of one login's list, for the reader's live inverter list (R12)
create function public.plants_of_login(p_login uuid) returns jsonb
  language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'vendor_id', p.vendor_id) order by p.id), '[]'::jsonb)
    from plants.login_plants lp join plants.plants p on p.id = lp.plant where lp.login = p_login
$$;
revoke all on function public.plants_of_login(uuid) from public, anon, authenticated;
grant execute on function public.plants_of_login(uuid) to service_role;

do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'plants' loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- when a user's list first showed a plant, and its name there (any user's when p_user is null):
-- mail reads this, not the lists (R2, R23 plant name)
create function public.plant_link(p_user uuid, p_plant bigint) returns jsonb
  language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('linked_at', u.linked_at, 'plant_name', u.plant_name)
    from plants.user_plants u
   where u.plant_id = p_plant and (p_user is null or u.user_id = p_user)
   order by u.share_gone_at is not null, u.linked_at limit 1
$$;
revoke all on function public.plant_link(uuid, bigint) from public, anon, authenticated;
grant execute on function public.plant_link(uuid, bigint) to service_role;

-- R26: the plant's own zone (IANA), for every local day, hour and date
create function plants.tz(p_plant bigint) returns text
  language sql stable security definer set search_path to '' as $$
  select coalesce((select p.time_zone from plants.plants p where p.id = p_plant),
                  (select m.default_time_zone from billing.markets m order by m.code limit 1))
$$;

-- poll_jobs_v2 returns the brand and its plant id now (R12): a new return type
drop function public.poll_jobs_v2(integer, integer, uuid, timestamptz);

-- claims take the brand's plant id, text (R11)
drop function public.share_claim_any(uuid, uuid, bigint, text);

-- the brand's id for one of our plants: only for calls to the brand (R12)
create function public.plant_vendor(p_plant bigint) returns text
  language sql stable security definer set search_path to '' as $$
  select p.vendor_id from plants.plants p where p.id = p_plant
$$;
revoke all on function public.plant_vendor(bigint) from public, anon, authenticated;
grant execute on function public.plant_vendor(bigint) to service_role;

-- ---------------------------------------------------------------------------
-- SOLAR-681 R2: other parts read this part's tables only through its doors. The doors are these
-- views (no tokens, no secrets) and the plants.* functions. Only this part's own files read the
-- tables; scripts/owners-check.mjs fails on a new direct read.
create or replace view plants.login_info as
  select id, account, user_id, brand, kind, username, status, linked_at, last_ok_at, last_error, last_try_at, last_try
    from plants.logins;
-- the reader's two job doors carry the login's access token (poll_jobs_v2, billing.history_take)
create or replace view plants.login_tokens as
  select id, access_token, access_expires_at from plants.logins;
create or replace view plants.list_info as
  select login, plant, plant_name, last_seen_at, gone_at, missing_since, linked_at from plants.login_plants;
create or replace view plants.claim_info as
  select plant, account, claimed_at, plant_name from plants.claims;
create or replace view plants.plant_info as
  select id, brand, vendor_id, time_zone, version, legacy, created_at from plants.plants;
create or replace view plants.settings as select * from public.plant_config;
create or replace view plants.inverter_info as select * from private.inverters;
create or replace view plants.meta_info as select * from private.meta;
create or replace view plants.config_log as select * from public.config_changes;
do $$
declare v text;
begin
  foreach v in array array['login_info', 'login_tokens', 'list_info', 'claim_info', 'plant_info', 'settings',
                           'inverter_info', 'meta_info', 'config_log'] loop
    execute format('revoke all on plants.%I from public, anon, authenticated', v);
  end loop;
end $$;

-- a plant's own rows in this part, for the history purge (private.purge_plant)
create or replace function plants.purge(p_plant bigint) returns jsonb
  language plpgsql security definer set search_path to '' as $$
declare n int; out jsonb := '{}';
begin
  delete from public.plant_config   where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from public.config_changes where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('config_changes', n);
  delete from private.meta          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  return out;
end $$;
revoke all on function plants.purge(bigint) from public, anon, authenticated;

-- R23: grid present is one rule: mains over 100 V (q_grid_present's, 0055). Every reader calls
-- this; the brand adapter's carry rule (brands/sunsynk/realtime.ts LOW_VOLT_V) uses the same
-- number, and scripts/sql/plants-tests.sql checks both.
create or replace function public.grid_live(p_volts double precision) returns boolean
  language sql immutable set search_path to '' as $$ select p_volts > 100 $$;

-- the edge's doors to plant settings (R2): which plants have settings, dropping the history
-- bookmarks of plants that are not read, and whether a plant's history is still loading
create or replace function public.plants_configured(p_plants bigint[]) returns setof bigint
  language sql stable security definer set search_path to '' as $$
  select c.plant_id from public.plant_config c where c.plant_id = any (coalesce(p_plants, '{}'))
$$;
create or replace function public.plant_bookmarks_clear(p_plants bigint[]) returns void
  language sql security definer set search_path to '' as $$
  update public.plant_config set backfill_next = null, backfill_until = null, temp_next = null
   where plant_id = any (coalesce(p_plants, '{}'))
$$;
create or replace function public.plant_history_loading(p_plant bigint) returns boolean
  language sql stable security definer set search_path to '' as $$
  select exists (select 1 from public.plant_config c where c.plant_id = p_plant and c.backfill_next is not null)
$$;
do $$
declare f text;
begin
  foreach f in array array['public.plants_configured(bigint[])', 'public.plant_bookmarks_clear(bigint[])', 'public.plant_history_loading(bigint)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- a user's logins' refresh tokens out of Vault (a token another user's copy still holds stays)
create or replace function plants.user_secrets_clear(p_user uuid) returns void
  language plpgsql security definer set search_path to '' as $$
declare r record;
begin
  for r in select l.id, l.refresh_secret_id from plants.logins l where l.user_id = p_user and l.refresh_secret_id is not null order by l.id loop
    if not exists (select 1 from plants.logins o where o.refresh_secret_id = r.refresh_secret_id and o.user_id <> p_user) then
      delete from vault.secrets s where s.id = r.refresh_secret_id;
    end if;
    update plants.logins set refresh_secret_id = null where id = r.id;
  end loop;
end $$;
revoke all on function plants.user_secrets_clear(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- every function that read or wrote the old tables, whole (supabase/schemas/functions/)

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

CREATE OR REPLACE FUNCTION billing.account_status(p_account uuid, p_at timestamp with time zone)
 RETURNS billing.status
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  a  billing.accounts;
  m  billing.markets;
  s  billing.subscriptions;
  r  billing.status;
  has_sub boolean;
  sub_end timestamptz;
  pds timestamptz;
  eff text;
  grant_places int;
  grant_last timestamptz;
  grant_any boolean;
begin
  select * into a from billing.accounts where id = p_account;
  if not found then return null; end if;
  select * into m from billing.markets where code = a.market;
  r.retention_days := m.retention_days;
  r.retry_days := m.retry_days;
  r.currency := m.currency;
  r.trial_ends_at := a.trial_ends_at;

  -- the latest plan begun by `at`
  select * into s from billing.subscriptions
   where account = p_account and started_at <= p_at order by started_at desc limit 1;
  has_sub := found;
  if has_sub then
    pds := case when s.status = 'past_due' then s.past_due_since end;
    if s.status = 'ended' then
      sub_end := s.ended_at;
    elsif s.cancel_at_period_end and s.period_end <= p_at then
      sub_end := s.period_end;
    else
      if pds is not null then
        r.plan_ends_at := billing.past_due_cutoff(pds, m.retry_days, coalesce(a.time_zone, m.default_time_zone));
        -- a payment made before the cutoff and not answered yet keeps it running, at most a day
        if r.plan_ends_at <= p_at and not (select h.in_flight from billing.renewal_hold(p_account, p_at) h) then
          sub_end := r.plan_ends_at;
        end if;
      end if;
    end if;
    eff := case when sub_end is not null and sub_end <= p_at then 'ended'
                when pds is not null and pds <= p_at then 'past_due'
                else 'active' end;
    if eff <> 'ended' then
      r.sub := s.id; r.plan := s.plan; r.interval := s.interval; r.amount_minor := s.amount_minor;
      r.currency := s.currency; r.period_end := s.period_end;
      r.cancel_at := case when s.cancel_at_period_end then s.period_end end;
      r.past_due_since := case when eff = 'past_due' then pds end;
      r.plan_ends_at := case when eff = 'past_due' then least(r.plan_ends_at, r.cancel_at) else r.cancel_at end;
    end if;
  end if;

  select coalesce(sum(g.places) filter (where g.starts_at <= p_at and (g.ends_at is null or g.ends_at > p_at)), 0),
         max(g.ends_at) filter (where g.ends_at <= p_at),
         coalesce(bool_or(g.starts_at <= p_at), false)
    into grant_places, grant_last, grant_any
    from billing.grants g where g.account = p_account;

  if eff in ('active', 'past_due') then
    r.state := eff;
    r.places := (select p.places from billing.plans p where p.code = s.plan) + s.extra_places + grant_places;
  elsif grant_places > 0 then
    r.state := 'active';
    r.places := grant_places;
  elsif a.trial_started_at <= p_at and p_at < a.trial_ends_at then
    r.state := 'trialing';
    r.places := m.trial_places;
  elsif a.trial_started_at <= p_at or has_sub or grant_any then
    r.state := 'ended';
  elsif exists (select 1 from billing.linked_plants(p_account))
        and not exists (select 1 from billing.linked_plants(p_account) t (x) left join billing.plant_facts p on p.plant = t.x
                         where p.trial_used_at is null or p.trial_used_by = p_account) then
    r.state := 'ended';                          -- nothing left to try: pay screen
  else
    r.state := 'none';
  end if;
  r.places := coalesce(r.places, 0);

  r.chosen := (select count(*) from billing.seats se
                where se.account = p_account and se.chosen_at <= p_at and (se.closed_at is null or se.closed_at > p_at));
  r.linked := (select count(*) from billing.linked_plants(p_account));
  r.must_choose := r.state in ('trialing', 'active', 'past_due') and r.chosen > r.places;

  if r.state = 'ended' then
    r.access_ended_at := greatest(case when a.trial_ends_at <= p_at then a.trial_ends_at end,
                                  case when sub_end <= p_at then sub_end end,
                                  grant_last);
  end if;
  return r;
end $function$;

CREATE OR REPLACE FUNCTION billing.alerts(p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select coalesce(jsonb_agg(a order by a->>'kind', a->>'ref'), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'attempt_pending', 'ref', pa.reference, 'since', pa.created_at, 'status', pa.status) a
      from billing.payment_attempts pa
     where pa.status in ('created', 'pending', 'unknown') and pa.created_at <= p_at - interval '1 hour'
    union all
    select jsonb_build_object('kind', 'refund_failed', 'ref', r.reference, 'tries', r.tries, 'error', r.last_error)
      from billing.refunds r where r.status = 'failed'
    union all
    -- 0272: emails wait in msg.outbox (both lanes). Late is from the event's due_at: a retry
    -- moves not_before on, so a row that keeps failing would never look an hour late. A "back"
    -- held for its "down" is not stuck; a stuck "down" counts on its own. Leased rows count.
    select jsonb_build_object('kind', 'outbox_backlog', 'ref', 'msg_email', 'waiting', count(*), 'oldest_due', min(q.due_at))
      from msg.outbox o join public.email_queue q on q.id = o.event_id
     where o.channel = 'email' and o.status = 'queued' and q.due_at <= p_at - interval '1 hour'
       and (q.pair_key is null or msg.email_down_state(q.user_id, q.pair_key) is distinct from 'wait')
    having count(*) > 0
    union all
    select jsonb_build_object('kind', 'outbox_backlog', 'ref', 'billing_outbox', 'waiting', count(*), 'oldest_due', min(o.not_before))
      from billing.outbox o where o.status = 'queued' and o.not_before <= p_at - interval '1 hour'
    having count(*) > 0
    union all
    select jsonb_build_object('kind', 'history_unprotected', 'ref', p.id::text, 'delete_at', ps->'delete_at')
      from plants.plant_info p cross join lateral billing.plant_state(p.id, p_at) ps
      left join billing.plant_facts f on f.plant = p.id
     where f.history_purged_at is null and ps->>'delete_at' is not null
       and (ps->>'delete_at')::timestamptz <= p_at - interval '1 hour'
       and not billing.payment_hold(p.id, p_at) and billing.has_history(p.id)
    union all
    -- history no seat holds, the last seat closed over an hour ago: the delete job missed it
    select jsonb_build_object('kind', 'history_unprotected', 'ref', p.id::text, 'closed_at', max(se.closed_at))
      from plants.plant_info p join billing.seats se on se.plant = p.id
      left join billing.plant_facts f on f.plant = p.id
     where f.history_purged_at is null
       and not exists (select 1 from billing.seats o where o.plant = p.id and o.closed_at is null)
     group by p.id
    having max(se.closed_at) <= p_at - interval '1 hour'
       and not billing.payment_hold(p.id, p_at) and billing.has_history(p.id)
    union all
    select jsonb_build_object('kind', 'many_switches', 'ref', e.account::text, 'switches', count(*))
      from billing.account_events e
     where e.kind = 'set_chosen_plants' and e.at > p_at - interval '7 days' and e.at <= p_at
       and e.before->'plants' is distinct from e.after->'plants'
     group by e.account having count(*) > 6
    union all
    select jsonb_build_object('kind', 'job_quiet', 'ref', j.job, 'last_run_at', h.last_run_at)
      from billing.switch_over so
     cross join (values ('delete', interval '30 minutes'), ('history', interval '10 minutes'),
                        ('billing-run', interval '26 hours')) j (job, quiet)
      left join billing.job_heartbeats h on h.job = j.job
     -- the delete job counts only once started (billing.start_delete_job, DEPLOY.md step 7)
     where (j.job <> 'delete' or h.job is not null)
       and coalesce(h.last_run_at, so.switched_at) <= p_at - j.quiet
  ) x
$function$;

CREATE OR REPLACE FUNCTION billing.apply_renewal(p_inv billing.invoices, p_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare dropped bigint[];
begin
  update billing.subscriptions
     set status = 'active', past_due_since = null, ended_at = null, price = p_inv.price, plan = p_inv.plan, interval = p_inv.interval,
         amount_minor = p_inv.plan_amount_minor, extra_place_minor = p_inv.extra_place_minor,
         extra_places = p_inv.extra_places, period_start = p_inv.period_start, period_end = p_inv.period_end,
         next_price = null, next_extra_places = null, version = version + 1
   where id = p_inv.subscription;
  -- a booked downgrade: the plants picked to drop go now
  dropped := array(select plant from billing.seats
                    where account = p_inv.account and closed_at is null and drop_at_period_end order by plant);
  if cardinality(dropped) > 0 then
    perform billing.lock_plants(dropped);
    update billing.seats set closed_at = p_at, close_reason = 'dropped', drop_at_period_end = false
     where account = p_inv.account and closed_at is null and drop_at_period_end;
    perform plants.bump(dropped);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION billing.delete_account(p_account uuid, p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  st billing.status;
  held bigint[];
  unprotected bigint[];
begin
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state not in ('none', 'trialing', 'ended') then
    raise exception 'a plan is running: cancel it and let it run out first' using errcode = '22023';
  end if;
  if exists (select 1 from billing.invoices where account = p_account and amount_owed_minor > 0) then
    raise exception 'money is owed' using errcode = '22023';
  end if;
  if exists (select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
              where i.account = p_account and pa.dispute_open) then
    raise exception 'a dispute is open' using errcode = '22023';
  end if;
  held := array(select plant from billing.seats where account = p_account and closed_at is null order by plant);
  perform billing.lock_plants(held);
  update billing.invoices set status = 'void' where account = p_account and status = 'open';
  -- the bills' plan link first: in one delete, the account's set-null on a bill can fire after
  -- its plan row is gone and fail that bill's plan check (depends on the constraints' order)
  update billing.invoices set subscription = null where account = p_account and subscription is not null;
  delete from billing.accounts where id = p_account;
  perform plants.bump(held);
  unprotected := array(select x from unnest(held) x where not (billing.plant_state(x, p_at)->>'protected')::boolean);
  perform billing.log_event(p_account, p_at, p_actor, 'delete_account', jsonb_build_object('state', st.state),
                            jsonb_build_object('unprotected', to_jsonb(unprotected)));
  return jsonb_build_object('deleted', true, 'unprotected', to_jsonb(unprotected));
end $function$;

CREATE OR REPLACE FUNCTION billing.delete_due(p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  p record;
  ps jsonb;
  deleted bigint[] := '{}';
  emptied bigint[] := '{}';
  held bigint[] := '{}';
  busy bigint[] := '{}';
  counts jsonb;
  out jsonb;
  now_at timestamptz;
begin
  if not billing.is_live() then return jsonb_build_object('live', false); end if;
  if not pg_try_advisory_xact_lock(hashtext('billing.delete_due')) then return jsonb_build_object('busy', true); end if;
  for p in select pp.id from plants.plant_info pp left join billing.plant_facts f on f.plant = pp.id
            where f.history_purged_at is null order by pp.id loop
    ps := billing.plant_state(p.id, p_at);
    continue when ps->>'delete_at' is null or (ps->>'delete_at')::timestamptz > p_at;
    -- a plant being written now is left for the next run
    perform 1 from plants.plant_info where id = p.id for update skip locked;
    if not found then busy := busy || p.id; continue; end if;
    -- the clock moved while the job ran: one time from here on, after the lock, for every
    -- check and the delete itself; a seat opened since the job started keeps the plant
    now_at := greatest(p_at, clock_timestamp());
    ps := billing.plant_state(p.id, now_at);
    continue when ps->>'delete_at' is null or (ps->>'delete_at')::timestamptz > now_at;
    continue when exists (select 1 from billing.seats s where s.plant = p.id and s.closed_at is null and s.chosen_at > p_at);
    if billing.payment_hold(p.id, now_at) then held := held || p.id; continue; end if;
    -- the full routine every time; what went is read from its counts
    counts := billing.purge_now(p.id, now_at);
    continue when counts is null;
    if exists (select 1 from jsonb_each_text(counts) c where c.value::bigint > 0) then deleted := deleted || p.id;
    else emptied := emptied || p.id; end if;
  end loop;
  out := jsonb_build_object('deleted', to_jsonb(deleted), 'empty', cardinality(emptied),
                            'held', to_jsonb(held), 'busy', to_jsonb(busy));
  perform billing.heartbeat('delete', p_at, out);
  return out;
end $function$;

CREATE OR REPLACE FUNCTION billing.fetch_lane(p_account uuid, p_plant bigint)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'private', 'pg_temp'
AS $function$
  select coalesce(
    (select l.id from plants.login_info l
       join plants.list_info lp on lp.login = l.id and lp.plant = p_plant and lp.gone_at is null
       join plants.login_info sa on sa.id = l.id and sa.status = 'ok'
      where l.account = p_account and l.status = 'ok'
      order by l.linked_at, l.id limit 1),
    (select sa.id from plants.claim_info c
       join plants.login_info sa on sa.kind = 'share' and sa.status = 'ok' and sa.brand = plants.brand_of(c.plant)
      where c.account = p_account and c.plant = p_plant limit 1))
$function$;

CREATE OR REPLACE FUNCTION billing.has_route(p_account uuid, p_plant bigint, p_need_ok boolean)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select exists (select 1 from plants.login_info l join plants.list_info lp on lp.login = l.id
                  where l.account = p_account and lp.plant = p_plant and lp.gone_at is null
                    and (not p_need_ok or l.status = 'ok'))
      or exists (select 1 from plants.claim_info c where c.account = p_account and c.plant = p_plant)
$function$;

CREATE OR REPLACE FUNCTION billing.history_take(p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  q record;
  tz text;
  today date;
  out jsonb;
begin
  if not billing.is_live() then return '[]'::jsonb; end if;
  if not pg_try_advisory_xact_lock(hashtext('billing.history_take')) then return '[]'::jsonb; end if;
  update billing.history_fetches h set status = 'dropped', drop_reason = 'switched_out', finished_at = p_at, claimed_until = null, claim = null
   where h.status in ('queued', 'running') and h.requested_at <= p_at and not billing.holds_plant(h.account, h.plant, p_at);
  -- a running fetch whose route changed (its login broke or no longer sees the plant, a claim
  -- went) or that is not read now (over the places): back to the queue, its days kept
  update billing.history_fetches h set status = 'queued', lane = null, claimed_until = null, claim = null
   where h.status = 'running' and h.requested_at <= p_at
     and (billing.fetch_lane(h.account, h.plant) is distinct from h.lane or not billing.reads_plant(h.account, h.plant, p_at));

  -- a login starts its next request when nothing on it has a step due or under way (a slowed
  -- fetch waiting for its next day does not hold it); on a shared login the account whose last
  -- fetch there started longest ago (or never) goes first
  for q in
    select h.id, h.plant, x.lane from billing.history_fetches h
     cross join lateral (select billing.fetch_lane(h.account, h.plant) lane) x
     where h.status = 'queued' and h.requested_at <= p_at and x.lane is not null
       and billing.reads_plant(h.account, h.plant, p_at)
     order by x.lane,
              (select max(o.started_at) from billing.history_fetches o where o.lane = x.lane and o.account = h.account) nulls first,
              h.requested_at, h.id
  loop
    continue when exists (select 1 from billing.history_fetches r where r.lane = q.lane and r.status = 'running'
                             and (r.next_step_at <= p_at or r.claimed_until > p_at))
               or exists (select 1 from billing.history_lanes hl where hl.lane = q.lane and hl.backoff_until > p_at);
    tz := plants.tz(q.plant);
    today := (p_at at time zone tz)::date;
    -- a fetch put back keeps its walk: started_at, floor and the next day stay
    update billing.history_fetches
       set status = 'running', lane = q.lane, started_at = coalesce(started_at, p_at), next_step_at = p_at,
           day_floor = coalesce(day_floor, today - 60), day_next = coalesce(day_next, today - 1),
           days_total = coalesce(days_total, 60), tries = 0
     where id = q.id;
  end loop;

  -- one step per login at a time: its earliest due fetch
  with due as (
    select distinct on (h.lane) h.id from billing.history_fetches h
     where h.status = 'running' and h.next_step_at <= p_at and (h.claimed_until is null or h.claimed_until <= p_at)
       and not exists (select 1 from billing.history_fetches o where o.lane = h.lane and o.status = 'running'
                          and o.id <> h.id and o.claimed_until > p_at)
       and not exists (select 1 from billing.history_lanes hl where hl.lane = h.lane and hl.backoff_until > p_at)
       and billing.reads_plant(h.account, h.plant, p_at)
       and exists (select 1 from plants.login_info sa where sa.id = h.lane and sa.status = 'ok')
     order by h.lane, h.next_step_at, h.id),
  w as (
    update billing.history_fetches h
       set claimed_until = p_at + interval '90 seconds', claim = gen_random_uuid(),
           version = (select bp.version from plants.plant_info bp where bp.id = h.plant)
     where h.id in (select id from due)
    returning h.*)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', w.id, 'claim', w.claim, 'plant', w.plant, 'account', w.account, 'day', w.day_next, 'floor', w.day_floor,
           'target_s', w.target_s, 'version', w.version,
           'timezone', plants.tz(w.plant), 'vendor_plant_id', (select p.vendor_id from plants.plant_info p where p.id = w.plant),
           'login', jsonb_build_object('id', sa.id, 'user_id', sa.user_id, 'username', sa.username, 'brand', sa.brand,
                                       'access_token', tk.access_token, 'access_expires_at', tk.access_expires_at))
           order by w.id), '[]'::jsonb)
    into out
    from w join plants.login_info sa on sa.id = w.lane join plants.login_tokens tk on tk.id = sa.id
    left join plants.settings c on c.plant_id = w.plant;
  perform billing.heartbeat('history', p_at, jsonb_build_object('handed_out', jsonb_array_length(out)));
  return out;
end $function$;

CREATE OR REPLACE FUNCTION billing.linked_plants(p_account uuid)
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select lp.plant from plants.login_info l join plants.list_info lp on lp.login = l.id
   where l.account = p_account and lp.gone_at is null
  union
  select c.plant from plants.claim_info c where c.account = p_account
$function$;

CREATE OR REPLACE FUNCTION billing.lock_plants(p_plants bigint[])
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select null from (select id from plants.plant_info where id = any (p_plants) order by id for update) x
$function$;

CREATE OR REPLACE FUNCTION billing.outbox_guard(o billing.outbox, p_at timestamp with time zone)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  st billing.status;
  inv billing.invoices;
  att billing.payment_attempts;
  ev billing.account_events;
  ms jsonb;
  u uuid;
  pm billing.payment_methods;
begin
  if o.account is null then return 'no account'; end if;
  if o.expires_at is not null and o.expires_at <= p_at then return 'expired'; end if;
  select user_id into u from billing.accounts where id = o.account;
  if u is null then return 'no account'; end if;
  if (select reminder from billing.outbox_kinds where key = o.key) and not public.email_wanted(u, 'reminders') then
    return 'reminders off';
  end if;
  st := billing.account_status(o.account, p_at);
  if o.invoice is not null then select * into inv from billing.invoices where id = o.invoice; end if;
  case o.key
    when 'receipt' then
      if inv.status is distinct from 'paid' then return 'bill not paid'; end if;
    when 'payment_failed' then
      if inv.status is distinct from 'open' then return 'bill settled'; end if;
      if st.state <> 'past_due' then return 'not past due'; end if;
      if st.plan_ends_at <= p_at then return 'past the pay-by date'; end if;
      -- a later try on the same bill has its own email
      if exists (select 1 from billing.payment_attempts pa where pa.invoice = inv.id and pa.status = 'failed'
                    and pa.channel in ('saved_card', 'none')
                    and pa.created_at > (select created_at from billing.payment_attempts where id = o.ref::uuid)) then
        return 'a later try';
      end if;
    when 'card_update', 'payment_due' then
      if inv.status is distinct from 'open' then return 'bill settled'; end if;
      if (billing.active_method(o.account)).id is not null then return 'card replaced'; end if;
      if st.state <> 'past_due' then return 'not past due'; end if;
      if st.plan_ends_at <= p_at then return 'past the pay-by date'; end if;
    when 'payment_reminder' then                                                  -- 0276
      return (billing.payment_reminder_check(o.account, o.invoice, p_at)).stop;
    when 'refund' then
      if not exists (select 1 from billing.refunds r where r.id = o.ref::uuid and r.status = 'processed') then
        return 'refund not processed';
      end if;
    when 'plan_ended' then
      if st.state <> 'ended' then return 'plan running again'; end if;
      if (select s.id from billing.subscriptions s where s.account = o.account order by started_at desc limit 1)
         is distinct from o.ref::uuid then return 'a later plan'; end if;
      if o.ended_at is not null
         and (select s.ended_at from billing.subscriptions s where s.id = o.ref::uuid) is distinct from o.ended_at then
        return 'ending no longer current';
      end if;
    when 'change_booked', 'change_undone' then
      select * into ev from billing.account_events where id = o.ref::bigint;
      if exists (select 1 from billing.account_events e where e.account = o.account and e.id > ev.id and e.actor = 'owner'
                    and e.kind in ('cancel', 'undo_cancel', 'downgrade', 'switch_interval')) then
        return 'changed again';
      end if;
      if st.state <> 'active' or st.sub is null then return 'plan not running'; end if;
      ms := billing.money_state(o.account, p_at, st.state);
      if ev.kind = 'cancel' and st.cancel_at is null then return 'cancel undone'; end if;
      if ev.kind = 'undo_cancel' and st.cancel_at is not null then return 'cancelled again'; end if;
      if o.key = 'change_booked' and ev.kind = 'downgrade' and ms->>'next_plan' is distinct from ev.after->>'plan' then
        return 'downgrade changed';
      end if;
      if ev.kind = 'switch_interval' and ms->>'next_interval' is distinct from ev.after->>'interval' then
        return 'interval changed';
      end if;
    when 'card_changed' then
      -- the same card, made active at the time this row was queued for (dedupe_key's last part):
      -- switching back and forth sends one email per real change
      pm := billing.active_method(o.account);
      if pm.id is distinct from o.ref::uuid
         or extract(epoch from coalesce(pm.activated_at, pm.created_at))::bigint::text is distinct from split_part(o.dedupe_key, ':', 3) then
        return 'card replaced';
      end if;
    when 'renewal_soon' then
      if st.state <> 'active' or st.cancel_at is not null or st.sub is distinct from o.ref::uuid then return 'not renewing'; end if;
    when 'card_expiring' then
      if (billing.active_method(o.account)).id is distinct from o.ref::uuid then return 'card replaced'; end if;
      if not (billing.money_state(o.account, p_at, st.state)->>'card_expires_first')::boolean then return 'card fine'; end if;
    when 'trial_ends_soon' then
      if st.state <> 'trialing' or extract(epoch from st.trial_ends_at)::bigint::text <> o.ref then return 'week over or paid'; end if;
    when 'trial_ended' then
      if st.state <> 'ended' or exists (select 1 from billing.subscriptions x where x.account = o.account) then return 'paid'; end if;
    when 'history_delete_soon' then
      if st.state <> 'ended' then return 'plan running again'; end if;
      if not exists (select 1 from jsonb_array_elements(billing.account_state(o.account, p_at)->'plants') p
                      where (p->>'chosen')::boolean and (p->>'delete_at')::timestamptz > p_at) then return 'nothing kept'; end if;
    when 'history_deleted' then
      if st.state <> 'ended' then return 'plan running again'; end if;
      if not exists (select 1 from billing.plant_facts p where p.plant = o.ref::bigint and p.history_purged_at is not null) then
        return 'history back';
      end if;
  end case;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION billing.outbox_on_purge()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare se record;
begin
  if new.history_purged_at is not null and (tg_op = 'INSERT' or old.history_purged_at is null) then
    for se in select s.account from billing.seats s where s.plant = new.plant and s.closed_at is null loop
      perform billing.outbox_put(se.account, 'history_deleted', null, new.plant::text,
                                 'history_deleted:' || se.account || ':' || new.plant || ':' || extract(epoch from new.history_purged_at)::bigint,
                                 new.history_purged_at, new.history_purged_at + interval '2 days', new.history_purged_at);
    end loop;
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION billing.outbox_take(p_limit integer DEFAULT 50, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  o billing.outbox;
  why text;
  out jsonb := '[]';
  inv billing.invoices;
  att billing.payment_attempts;
  pm billing.payment_methods;
  u record;
begin
  -- before the switch the old emails still go; these wait and go once it is on
  if not billing.is_live() then return '[]'::jsonb; end if;
  for o in select * from billing.outbox
            where status = 'queued' and not_before <= p_at and (claimed_until is null or claimed_until <= p_at)
              -- held, not dropped: a renewal paid before the cutoff may still be answered (0248)
              and not case when key = 'plan_ended' then billing.plan_ended_held(account, ref, p_at)
                              when key = 'payment_reminder' then                                 -- 0276
                                (select c.stop is null and c.wait is not null
                                   from billing.payment_reminder_check(account, invoice, p_at) c)
                              else false end
            order by not_before, id limit p_limit for update skip locked loop
    why := billing.outbox_guard(o, p_at);
    if why is not null then
      update billing.outbox set status = 'dropped', drop_reason = why, claimed_until = null where id = o.id;
      continue;
    end if;
    select au.id, au.email, ep.unsub_token into u
      from billing.accounts a join auth.users au on au.id = a.user_id
      left join public.email_prefs ep on ep.user_id = au.id where a.id = o.account;
    if u.email is null then
      update billing.outbox set status = 'dropped', drop_reason = 'no email', claimed_until = null where id = o.id;
      continue;
    end if;
    -- 0281 (SOLAR-679 F13): bounced for good or marked as spam; never sent, so never tried again
    if private.mail_blocked(u.email) then
      update billing.outbox set status = 'dropped', drop_reason = 'address blocked', claimed_until = null where id = o.id;
      continue;
    end if;
    inv := null; att := null; pm := null;
    if o.invoice is not null then
      select * into inv from billing.invoices where id = o.invoice;
      select * into att from billing.payment_attempts where invoice = inv.id and status in ('success', 'failed')
       order by (status = 'success') desc, created_at desc limit 1;
      -- a failed or refused try's email names that try's card; card_update rows queued before
      -- 0248 have no ref: the latest refused saved-card try on the bill
      if o.key in ('payment_failed', 'card_update', 'payment_due') then
        select * into att from billing.payment_attempts where invoice = inv.id and id::text = o.ref;
        if att.id is null and o.key = 'card_update' then
          select * into att from billing.payment_attempts where invoice = inv.id and channel = 'saved_card' and hard_decline
           order by created_at desc limit 1;
        end if;
      end if;
      if att.payment_method is not null then select * into pm from billing.payment_methods where id = att.payment_method; end if;
    end if;
    update billing.outbox set claimed_until = p_at + interval '5 minutes', tries = tries + 1 where id = o.id;
    out := out || jsonb_build_array(jsonb_build_object(
      'id', o.id, 'key', o.key, 'user', u.id, 'email', u.email,
      -- a reminder always carries its unsubscribe link: the settings row is made if missing
      'unsub_token', case when (select reminder from billing.outbox_kinds where key = o.key)
                          then public.email_unsub_token(u.id) else u.unsub_token end,
      'reminder', (select reminder from billing.outbox_kinds where key = o.key),
      'state', billing.screen_state(o.account, p_at),
      -- the frozen bill a receipt reads
      'bill', case when inv.id is not null then jsonb_build_object(
                'kind', inv.kind, 'plan', inv.plan, 'plan_name', inv.plan_name,
                'interval', inv.interval, 'amount_minor', inv.amount_minor, 'currency', inv.currency,
                'next_amount_minor', case when inv.next_interval is not null
                  then (select np.amount_minor + inv.extra_places * np.extra_place_minor
                          from billing.price_keeping_offer(inv.plan, (select market from billing.accounts where id = inv.account),
                                                           inv.next_interval, inv.offer, inv.paid_at) np)
                  else inv.plan_amount_minor + inv.extra_places * inv.extra_place_minor end,
                'starts_now', inv.kind = 'upgrade' and inv.period_key like '%@%',
                'period_start', inv.period_start, 'period_end', inv.period_end, 'paid_at', inv.paid_at,
                'reference', att.reference, 'card_type', pm.card_type, 'last4', pm.last4) end,
      'refund', (select jsonb_build_object('amount_minor', coalesce(r.amount_minor, pa.amount_minor), 'currency',
                         coalesce(r.currency, pa.currency), 'reference', r.reference, 'reason', r.reason,
                         'paid_at', pa.settled_at, 'paid_minor', pa.amount_minor,
                         -- the card the refunded payment came from, not the one saved now
                         'card_type', rpm.card_type, 'last4', rpm.last4)
                   from billing.refunds r left join billing.payment_attempts pa on pa.id = r.attempt
                   left join billing.payment_methods rpm on rpm.id = pa.payment_method
                  where o.key = 'refund' and r.id = o.ref::uuid),
      -- a plan's end: its date, why, and whether a renewal payment was never answered
      'ended', case when o.key = 'plan_ended' then billing.plan_ended_facts(o) end,
      'event', (select jsonb_build_object('kind', e.kind, 'before', e.before, 'after', e.after)
                  from billing.account_events e where o.key in ('change_booked', 'change_undone') and e.id = o.ref::bigint),
      'plant', (select jsonb_build_object('id', p.id, 'name', coalesce((select lp.plant_name from plants.list_info lp
                         join plants.login_info l on l.id = lp.login where l.account = o.account and lp.plant = p.id limit 1),
                         (select pu.plant_name from plants.user_plants pu where pu.plant_id = p.id and pu.user_id = u.id limit 1)))
                  from plants.plant_info p where o.key = 'history_deleted' and p.id = o.ref::bigint)));
  end loop;
  return out;
end $function$;

CREATE OR REPLACE FUNCTION billing.plant_state(p_plant bigint, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  purged boolean;
  se record;
  st billing.status;
  is_protected boolean := false;
  is_read boolean := false;
  latest timestamptz;
  seat_count int := 0;
  delete_at timestamptz;
begin
  if not exists (select 1 from plants.plant_info where id = p_plant) then return null; end if;
  purged := exists (select 1 from billing.plant_facts f where f.plant = p_plant and f.history_purged_at is not null);
  for se in select s.account from billing.seats s
             where s.plant = p_plant and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  loop
    seat_count := seat_count + 1;
    st := billing.account_status(se.account, p_at);
    if st.state in ('trialing', 'active', 'past_due') then
      is_protected := true;
      if not st.must_choose and billing.has_route(se.account, p_plant, true) then is_read := true; end if;
    elsif st.state = 'ended' and st.access_ended_at is not null then
      latest := greatest(latest, st.access_ended_at + make_interval(days => st.retention_days));
    end if;
  end loop;
  is_read := is_read and not private.history_deleting(p_plant);           -- 0277
  delete_at := case when is_protected or purged then null
                    when seat_count = 0 then p_at
                    else latest end;
  return jsonb_build_object(
    'plant', p_plant,
    'protected', is_protected,
    'read_now', is_read,
    'delete_at', delete_at,
    'purged', purged,
    'deleting', private.history_deleting(p_plant),                        -- 0277
    'open_seats', seat_count);
end $function$;

CREATE OR REPLACE FUNCTION billing.plants_read_now(p_plants bigint[], p_at timestamp with time zone)
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  with se as (
    select s.account, s.plant from billing.seats s
     where s.plant = any (p_plants) and not private.history_deleting(s.plant)   -- 0277
       and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  ), st as (
    select * from billing.accounts_live(array(select distinct account from se), p_at)
  )
  select distinct se.plant
    from se join st on st.account = se.account and st.live and not st.must_choose
   where exists (select 1 from plants.login_info l join plants.list_info lp on lp.login = l.id
                  where l.account = se.account and lp.plant = se.plant and lp.gone_at is null and l.status = 'ok')
      or exists (select 1 from plants.claim_info c where c.account = se.account and c.plant = se.plant)
$function$;

CREATE OR REPLACE FUNCTION billing.purge_now(p_plant bigint, p_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare ps jsonb;
begin
  if not billing.is_live() then return null; end if;
  ps := billing.plant_state(p_plant, p_at);
  if ps->>'delete_at' is null or (ps->>'delete_at')::timestamptz > p_at or billing.payment_hold(p_plant, p_at) then
    return null;
  end if;
  -- 0277: the rows go in the background (private.history_delete_run); from here the plant
  -- is hidden, not read and not written while it waits
  insert into private.history_delete_queue (plant_id, queued_at) values (p_plant, clock_timestamp())
  on conflict (plant_id) do nothing;
  delete from private.refill_queue where plant_id = p_plant;
  update public.plant_config set backfill_next = null, backfill_until = null, backfill_tries = 0, temp_next = null
   where plant_id = p_plant;
  insert into billing.plant_facts (plant, history_purged_at) values (p_plant, p_at)
  on conflict (plant) do update set history_purged_at = excluded.history_purged_at;
  perform plants.bump(array[p_plant]);
  update billing.history_fetches set status = 'dropped', drop_reason = 'deleted', finished_at = p_at, claimed_until = null
   where plant = p_plant and status in ('queued', 'running');
  return jsonb_build_object('queued', 1);                                  -- 0277: delete_due counts it as deleted
end $function$;

CREATE OR REPLACE FUNCTION billing.reading_routes(p_at timestamp with time zone)
 RETURNS TABLE(plant bigint, account uuid, lane uuid, via_share boolean, since timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'private', 'pg_temp'
AS $function$
  with seat as (
    select s.account, s.plant from billing.seats s
     where s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  ), live as (
    select x.account from (select distinct account from seat) x
     cross join lateral billing.account_status(x.account, p_at) st
     where st.state in ('trialing', 'active', 'past_due') and not st.must_choose
  )
  select se.plant, se.account, l.id, false, l.linked_at
    from seat se join live using (account)
    join plants.login_info l on l.account = se.account and l.status = 'ok'
    join plants.list_info lp on lp.login = l.id and lp.plant = se.plant and lp.gone_at is null
    join plants.login_info sa on sa.id = l.id and sa.status = 'ok'
  union all
  select se.plant, se.account, sa.id, true, c.claimed_at
    from seat se join live using (account)
    join plants.claim_info c on c.plant = se.plant and c.account = se.account
    join plants.login_info sa on sa.kind = 'share' and sa.status = 'ok' and sa.brand = plants.brand_of(c.plant)
$function$;

CREATE OR REPLACE FUNCTION billing.reading_routes_set(p_at timestamp with time zone)
 RETURNS TABLE(plant bigint, account uuid, lane uuid, via_share boolean, since timestamp with time zone, ends_at timestamp with time zone)
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'private', 'pg_temp'
AS $function$
  with seat as (
    select s.account, s.plant, s.closed_at from billing.seats s
     where s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  ), live as (
    select st.account, st.ends_at
      from billing.accounts_live(array(select distinct account from seat), p_at) st
     where st.live and not st.must_choose
  )
  select se.plant, se.account, l.id, false, l.linked_at, least(lv.ends_at, se.closed_at)
    from seat se join live lv on lv.account = se.account
    join plants.login_info l on l.account = se.account and l.status = 'ok'
    join plants.list_info lp on lp.login = l.id and lp.plant = se.plant and lp.gone_at is null
    join plants.login_info sa on sa.id = l.id and sa.status = 'ok'
  union all
  select se.plant, se.account, sa.id, true, c.claimed_at, least(lv.ends_at, se.closed_at)
    from seat se join live lv on lv.account = se.account
    join plants.claim_info c on c.plant = se.plant and c.account = se.account
    join plants.login_info sa on sa.kind = 'share' and sa.status = 'ok' and sa.brand = plants.brand_of(c.plant)
$function$;

CREATE OR REPLACE FUNCTION billing.readings_start(p_account uuid, p_plants bigint[], p_at timestamp with time zone)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into private.plant_alert_state (plant_id, started_at)
  select c.plant_id, extract(epoch from p_at)::bigint from plants.settings c
   where c.plant_id = any (p_plants)
     and not exists (select 1 from billing.seats s where s.plant = c.plant_id and s.account <> p_account
                        and s.closed_at is null and billing.reads_plant(s.account, c.plant_id, p_at))
  on conflict (plant_id) do update
    set started_at = greatest(coalesce(private.plant_alert_state.started_at, 0), excluded.started_at)
$function$;

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
           'logins', coalesce((select jsonb_agg(l.id order by l.linked_at) from plants.login_info l
                                 join plants.list_info lp on lp.login = l.id
                                where l.account = p_account and lp.plant = (p->>'plant')::bigint and lp.gone_at is null), '[]'::jsonb),
           'gone_logins', coalesce((select jsonb_agg(l.id order by l.linked_at) from plants.login_info l
                                      join plants.list_info lp on lp.login = l.id
                                     where l.account = p_account and lp.plant = (p->>'plant')::bigint and lp.gone_at is not null), '[]'::jsonb),
           'claimed', exists (select 1 from plants.claim_info c where c.account = p_account and c.plant = (p->>'plant')::bigint),
           -- it came through the share: removing the shared group lets it go (api_link_remove)
           'shared', exists (select 1 from plants.user_plants pu join plants.login_info sa on sa.id = pu.account_id
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
                          from plants.login_info l where l.account = p_account), '[]'::jsonb),
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
    select x into bad from unnest(want) x join billing.plant_facts p on p.plant = x
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

CREATE OR REPLACE FUNCTION billing.write_allowed(p_versions jsonb, p_at timestamp with time zone)
 RETURNS bigint[]
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  ok bigint[] := '{}';
  p record;
begin
  for p in select bp.id, bp.version from plants.plant_info bp
            where bp.id in (select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k)
            order by bp.id for share
  loop
    if p.version = (p_versions->>(p.id::text))::bigint
       and (billing.plant_state(p.id, p_at)->>'read_now')::boolean then
      ok := ok || p.id;
    end if;
  end loop;
  return ok;
end $function$;

CREATE OR REPLACE FUNCTION billing.write_allowed_set(p_versions jsonb, p_at timestamp with time zone)
 RETURNS bigint[]
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare ids bigint[];
begin
  ids := array(select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k);
  perform 1 from plants.plant_info where id = any (ids) order by id for share;
  return array(select bp.id from plants.plant_info bp
                where bp.id = any (ids)
                  and bp.version = (p_versions->>(bp.id::text))::bigint
                  and bp.id in (select billing.plants_read_now(ids, p_at))
                order by bp.id);
end $function$;

CREATE OR REPLACE FUNCTION billing.write_seats(p_account uuid, p_want bigint[], p_at timestamp with time zone, p_reason text DEFAULT 'switched'::text, p_counts boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare had bigint[]; held boolean;
begin
  held := billing.reading_held(p_account, p_at);                                  -- 0256
  had := array(select plant from billing.seats where account = p_account and closed_at is null order by 1);
  update billing.seats set closed_at = p_at, close_reason = p_reason
   where account = p_account and closed_at is null and plant <> all (p_want);
  insert into billing.seats (account, plant, chosen_at)
  select p_account, x, p_at from unnest(p_want) x where x <> all (had);
  insert into billing.plant_facts as f (plant, trial_used_at, trial_used_by)
  select x, p_at, p_account from unnest(p_want) x where x <> all (had)
  on conflict (plant) do update set trial_used_at = coalesce(f.trial_used_at, excluded.trial_used_at),
                                    trial_used_by = coalesce(f.trial_used_by, excluded.trial_used_by)
   where f.trial_used_at is null or f.trial_used_by is null;
  perform plants.bump(array(select x from unnest(p_want || had) x where not (x = any (p_want) and x = any (had))));
  update billing.history_fetches set status = 'dropped', drop_reason = 'switched_out', finished_at = p_at, claimed_until = null
   where account = p_account and status in ('queued', 'running') and plant = any (had) and plant <> all (p_want);
  -- a seat opening (or a plan restarting) on a deleted plant: it gathers history again. The
  -- caller holds the plant locks, so no write path has to touch the row.
  update billing.plant_facts set history_purged_at = null
   where plant = any (p_want) and history_purged_at is not null;
  -- a plant switched out that no account keeps is deleted now, under its lock, so the
  -- pop-up's "deleted now" holds even if the owner switches straight back
  perform billing.purge_now(x, p_at) from unnest(had) x where x <> all (p_want);
  perform billing.request_history(p_account, array(select x from unnest(p_want) x where x <> all (had)), p_at, p_counts);
  perform billing.readings_start(p_account, case when held then p_want                       -- 0256
                                      else array(select x from unnest(p_want) x where x <> all (had)) end, p_at);
end $function$;

CREATE OR REPLACE FUNCTION msg.email_guard(p_o msg.outbox)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case
           when p_o.expires_at <= now() then 'too old'
           when q.id is null then 'event gone'
           -- kept in the app's bell, no email (notify build, SOLAR-415)
           when q.kind in ('batt_hot_back', 'bank_drift_back') then 'no email for this kind'
           when q.user_id is not null and private.email_switch_of(q.kind, q.data) is not null
                and not public.email_wanted(q.user_id, private.email_switch_of(q.kind, q.data)) then 'switched off'
           when q.plant_id is not null and q.user_id is not null and q.kind not in ('needs_relink', 'share_removed', 'plant_off_login')
                and not exists (select 1 from plants.user_plants pu where pu.user_id = q.user_id and pu.plant_id = q.plant_id)
             then 'plant removed'
           -- plan, chosen plant, still reached: asked again when sent (email_claim 0247)
           when q.kind like 'report\_%' and q.user_id is not null
                and not billing.report_wanted((select ba.id from billing.accounts ba where ba.user_id = q.user_id), q.plant_id)
             then 'report not wanted'
           -- reconnect: the login may hold other chosen plants; email_claim never asked (review).
           -- share_removed / plant_off_login: the plant has just left the account.
           when q.plant_id is not null and q.user_id is not null and not msg.email_any_plant(q.kind) and not exists (
                  select 1 from billing.seats se join billing.accounts ba on ba.id = se.account
                   where ba.user_id = q.user_id and se.plant = q.plant_id and se.closed_at is null)
             then 'plant not chosen'
           -- needs_relink is queued just before the login is marked broken (0261)
           when q.plant_id is not null and q.user_id is not null and not msg.email_any_plant(q.kind)
                and not private.plant_live(q.user_id, q.plant_id) then 'plant not live'
           when q.kind = 'welcome' and exists (select 1 from plants.user_plants pu where pu.user_id = q.user_id)
             then 'plant linked'
           when q.kind = 'need_a_hand' and exists (select 1 from plants.login_info a where a.user_id = q.user_id)
                and not private.pick_waiting(q.user_id)
             then 'login added'
           when q.kind = 'add_plant_reminder'
                and (exists (select 1 from plants.login_info a where a.user_id = q.user_id)
                     or exists (select 1 from plants.user_plants pu where pu.user_id = q.user_id))
             then 'login or plant added'
           when coalesce(q.to_email, (select u.email::text from auth.users u where u.id = q.user_id), p_o.to_email) is null
             then 'no address'
           -- bounced for good, marked as spam or on the sender's block list (0281, SOLAR-679 F13)
           when private.mail_blocked(coalesce(q.to_email, (select u.email::text from auth.users u where u.id = q.user_id), p_o.to_email))
             then 'address blocked'
           when q.pair_key is not null then
             case msg.email_down_state(q.user_id, q.pair_key)
               when 'wait' then 'wait' when 'dropped' then 'down not sent' end
         end
    from (select 1) one
    left join public.email_queue q on q.id = p_o.event_id
$function$;

CREATE OR REPLACE FUNCTION msg.push_guard(p_o msg.outbox)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case
           when p_o.expires_at <= now() then 'too old'
           when q.id is null then 'event gone'
           when q.plant_id is not null
                and not exists (select 1 from plants.user_plants pu where pu.user_id = q.user_id and pu.plant_id = q.plant_id)
             then 'plant removed'
           when q.plant_id is not null and not exists (
                  select 1 from billing.seats se join billing.accounts ba on ba.id = se.account
                   where ba.user_id = q.user_id and se.plant = q.plant_id and se.closed_at is null)
             then 'plant not chosen'
           -- needs_relink is queued just before the login is marked broken (trigger order on
           -- sunsynk_accounts), so its plant is never read at send time: no live test for the login kinds
           when q.plant_id is not null and q.kind not in ('needs_relink', 'relinked')
                and not private.plant_live(q.user_id, q.plant_id) then 'plant not live'
           when not private.push_wanted(q.user_id, private.email_switch(q.kind)) then 'switched off'
           when q.pair_key is not null then
             case msg.push_down_state(q.user_id, q.pair_key)
               when 'wait' then 'wait' when 'dropped' then 'down had no pop-up' end
         end
    from (select 1) one
    left join public.email_queue q on q.id = p_o.event_id
$function$;

CREATE OR REPLACE FUNCTION private.alerts_minute()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  last_done bigint := (select c.value::bigint from public.app_config c where c.key = 'ALERTS_DONE_TS');
  -- two minutes back: every read of that minute has saved or given up by then (50 s deadline)
  upto bigint := (floor(extract(epoch from now()) / 60) * 60)::bigint - 120;
  m bigint;
  n int := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('private.alerts_minute')) then return jsonb_build_object('busy', true); end if;
  m := greatest(coalesce(last_done, upto - 60), upto - 600) + 60;
  while m <= upto loop
    perform public.email_poll_step(m, '[]'::jsonb, array(select distinct a.plant_id from public.agg_minute a where a.ts = m order by 1));
    insert into public.app_config (key, value, note) values ('ALERTS_DONE_TS', m, 'the last minute the alert step ran for (private.alerts_minute)')
    on conflict (key) do update set value = excluded.value;
    n := n + 1;
    m := m + 60;
  end loop;
  return jsonb_build_object('minutes', n, 'upto', upto);
end $function$;

CREATE OR REPLACE FUNCTION private.call_fn(p_path text, p_body jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 55000)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare rid bigint;
begin
  rid := net.http_post(
    url := private.functions_url() || '/' || p_path,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
      'Content-Type', 'application/json'),
    body := p_body,
    timeout_milliseconds := p_timeout_ms);
  insert into private.fn_calls (id, fn, shard, timeout_ms)
  values (rid, split_part(split_part(p_path, '?', 1), '/', 1) || coalesce(':' || (p_body ->> 'task'), ''), (p_body ->> 'shard')::int, p_timeout_ms)
  on conflict (id) do nothing;
  return rid;
end $function$;

CREATE OR REPLACE FUNCTION private.email_enqueue_plant(p_plant bigint, p_kind text, p_key text, p_data jsonb, p_pair_key text DEFAULT NULL::text, p_priority smallint DEFAULT 0)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
  select pu.user_id, p_plant, p_kind, p_key, p_pair_key, p_data, p_priority
    from plants.user_plants pu where pu.plant_id = p_plant
  on conflict do nothing;
$function$;

CREATE OR REPLACE FUNCTION private.email_on_relink()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  now_s bigint := extract(epoch from now())::bigint;
  since_s bigint := coalesce(extract(epoch from old.last_ok_at)::bigint, extract(epoch from now())::bigint);  -- 0164: last good poll
  names jsonb;
  r record;
  n int := 0;
begin
  -- 0177: the share login. Each owner of a claimed shared plant gets one email when it
  -- stops and one when it is back. No sign-in wording: owners can't act on it. The
  -- company user, who owns the login, gets nothing.
  if new.kind = 'share' then
    if new.status = 'needs_reconnect' and old.status is distinct from 'needs_reconnect' then
      insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
      select o.user_id, o.plant_id, 'share_down', 'share_down:' || new.id || ':' || o.user_id || ':' || now_s,
             jsonb_build_object('account', new.id, 'since', since_s, 'plants', o.names), 0
        from (select pu.user_id, (array_agg(pu.plant_id order by pu.linked_at))[1] plant_id,
                     jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at) names
                from plants.user_plants pu
               where pu.account_id = new.id and pu.via_share and pu.share_gone_at is null and exists (select 1 from billing.seats se join billing.accounts ba on ba.id = se.account
                    where ba.user_id = pu.user_id and se.plant = pu.plant_id and se.closed_at is null)
               group by pu.user_id) o
      on conflict do nothing;
    elsif old.status = 'needs_reconnect' and new.status = 'ok' then
      -- each owner's latest "stopped" with no "back" yet; paired so email_claim drops a
      -- "back" whose "stopped" never went
      insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
      select d.user_id, d.plant_id, 'share_back', 'share_back:' || new.id || ':' || d.user_id || ':' || now_s, d.key,
             jsonb_build_object('account', new.id, 'since', coalesce((d.data->>'since')::bigint, extract(epoch from d.created_at)::bigint),
                                'at', now_s, 'plants', d.data->'plants'), 0
        from (select distinct on (q.user_id) q.* from public.email_queue q
               where q.kind = 'share_down' and q.data->>'account' = new.id::text
               order by q.user_id, q.id desc) d
       where not exists (select 1 from public.email_queue b where b.user_id = d.user_id and b.pair_key = d.key)
      on conflict do nothing;
    end if;
    return null;
  end if;

  -- every plant this user has on the login, oldest link first; the email lists them all
  select coalesce(jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at), '[]'::jsonb)
    into names
    from plants.user_plants pu where pu.account_id = new.id and pu.user_id = new.user_id;

  if new.status = 'needs_reconnect' and old.status is distinct from 'needs_reconnect' then
    for r in select pu.plant_id from plants.user_plants pu
              where pu.account_id = new.id and pu.user_id = new.user_id order by pu.linked_at loop  -- 0232
      n := n + 1;
      insert into public.email_queue (user_id, plant_id, kind, key, data, priority, status, last_error)
      values (new.user_id, r.plant_id, 'needs_relink', 'needs_relink:' || new.id || ':' || r.plant_id || ':' || now_s,
              jsonb_build_object('account', new.id, 'since', since_s, 'plants', names), 0,
              case when n = 1 then 'queued' else 'skipped' end, case when n > 1 then 'one email per login' end)
      on conflict do nothing;
    end loop;
    -- a login with no plant still gets its email, as before
    if n = 0 then
      insert into public.email_queue (user_id, kind, key, data, priority)
      values (new.user_id, 'needs_relink', 'needs_relink:' || new.id || ':' || now_s,
              jsonb_build_object('account', new.id, 'since', since_s, 'plants', names), 0)
      on conflict do nothing;
    end if;

  elsif old.status = 'needs_reconnect' and new.status = 'ok' then
    -- each plant's latest dead-login row with no "back" yet
    for r in
      select d.plant_id, d.key, d.status, coalesce((d.data->>'since')::bigint, extract(epoch from d.created_at)::bigint) since
        from plants.user_plants pu
        cross join lateral (select q.* from public.email_queue q
                             where q.user_id = new.user_id and q.plant_id = pu.plant_id and q.kind = 'needs_relink'
                               and q.data->>'account' = new.id::text
                             order by q.id desc limit 1) d
       where pu.account_id = new.id and pu.user_id = new.user_id
         and not exists (select 1 from public.email_queue b where b.user_id = new.user_id and b.pair_key = d.key)
       order by pu.linked_at
    loop
      -- the email goes on the plant whose "down" emailed, so email_claim pairs them
      insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority, status, last_error)
      values (new.user_id, r.plant_id, 'relinked', 'relinked:' || new.id || ':' || r.plant_id || ':' || now_s, r.key,
              jsonb_build_object('account', new.id, 'since', r.since, 'at', now_s, 'plants', names), 0,
              case when r.status <> 'skipped' then 'queued' else 'skipped' end,
              case when r.status = 'skipped' then 'one email per login' end)
      on conflict do nothing;
    end loop;
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION private.email_plant_apply(p_plant bigint, p_ts bigint, f jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  s private.plant_alert_state;
  present boolean := (f->>'present')::boolean;
  dev bigint := (f->>'dev')::bigint;
  temp numeric := (f->>'temp')::numeric;
  spread numeric := (f->>'spread')::numeric;
  k text;
  off jsonb;                                                                     -- 0164
begin
  insert into private.plant_alert_state (plant_id) values (p_plant) on conflict do nothing;
  select * into s from private.plant_alert_state where plant_id = p_plant for update;
  if s.stepped_ts is not null and p_ts <= s.stepped_ts then return; end if;

  -- Grid. Unknown minutes (no voltage reported) are skipped. Back needs 5 known minutes
  -- with grid once a Grid off went out (0151); a dip inside them is the same outage.
  if present is not null then
    if present is distinct from s.grid_run_on then
      s.grid_run_on := present; s.grid_run_n := 1; s.grid_run_start := p_ts;
    else
      s.grid_run_n := s.grid_run_n + 1;
    end if;
    if s.grid_on is distinct from s.grid_run_on
       and s.grid_run_n >= (case when not s.grid_run_on then 3 when s.grid_off_key is not null then 5 else 2 end) then
      if s.grid_on is null then
        null;                                       -- first state seen: taken silently
      elsif not s.grid_run_on then
        k := 'grid_down:' || p_plant || ':' || s.grid_run_start;
        off := private.grid_off_start(p_plant, s.grid_run_start);                    -- 0164
        perform private.email_enqueue_plant(p_plant, 'grid_down', k, off || jsonb_build_object(   -- 0164
          'chargePct', (select round(a.soc)::int from public.agg_minute a
                         where a.plant_id = p_plant and a.ts between p_ts - 600 and p_ts and a.soc is not null
                         order by a.ts desc limit 1)));
        s.grid_off_key := k;
        s.grid_run_start := (off->>'since')::bigint;                                 -- 0164: grid back counts from here
      elsif s.grid_off_key is not null then
        perform private.email_enqueue_plant(p_plant, 'grid_back', 'grid_back:' || p_plant || ':' || s.grid_since,
          jsonb_build_object('since', s.grid_since, 'at', s.grid_run_start), s.grid_off_key);
        s.grid_off_key := null;
      end if;
      s.grid_on := s.grid_run_on; s.grid_since := s.grid_run_start;
    end if;
  end if;

  -- Readings: SunSynk's own clock, the newest device_time on the plant this minute.
  -- While stale, back once readings have come for 15 min with no gap over 10 min (0151).
  if dev is not null and dev > coalesce(s.last_dev, 0) then
    if s.stale then
      if s.stale_clear_at is null or dev - s.last_dev > 600 then s.stale_clear_at := dev; end if;
      if extract(epoch from now()) - dev <= 900 and dev - s.stale_clear_at >= 900 then
        if s.stale_key is not null then
          perform private.email_enqueue_plant(p_plant, 'logger_back', 'logger_back:' || substr(s.stale_key, 14),
            jsonb_build_object('since', split_part(s.stale_key, ':', 3)::bigint, 'at', s.stale_clear_at), s.stale_key);
        end if;
        s.stale := false; s.stale_key := null; s.stale_clear_at := null;
      end if;
    end if;
    s.last_dev := dev;
  end if;

  -- Battery temperature: the hottest inverter this minute, over 45 C (unrounded, as the
  -- app judges it) for 3 minutes in a row. A minute with no temperature, or a gap of
  -- more than 2 minutes, starts the count again. Ends after 15 min at 43 C or below.
  if (f->>'has_batt')::boolean and temp is not null then
    s.hot_run_n := case when temp <= 45 then 0
                        when p_ts - coalesce(s.hot_at, 0) <= 120 then s.hot_run_n + 1 else 1 end;
    s.hot_temp := round(temp); s.hot_at := p_ts;
    if not s.hot and s.hot_run_n >= 3 then
      s.hot := true; s.hot_since := p_ts - 120; s.hot_n := 1; s.hot_sent_at := now(); s.hot_clear_at := null;
      perform private.email_enqueue_plant(p_plant, 'batt_hot', 'batt_hot:' || p_plant || ':' || s.hot_since || ':1',
        jsonb_build_object('at', p_ts, 'tempC', round(temp)));
    elsif s.hot and temp <= 43 then
      s.hot_clear_at := coalesce(s.hot_clear_at, p_ts);
      if p_ts - s.hot_clear_at >= 900 then
        perform private.email_enqueue_plant(p_plant, 'batt_hot_back', 'batt_hot_back:' || p_plant || ':' || s.hot_since,
          jsonb_build_object('since', s.hot_since, 'at', s.hot_clear_at, 'tempC', round(temp)),
          'batt_hot:' || p_plant || ':' || s.hot_since || ':1');
        s.hot := false; s.hot_clear_at := null;
      end if;
    elsif s.hot then
      s.hot_clear_at := null;
    end if;
  end if;

  -- Charge spread between inverters' own batteries. Ends after 15 min under 8 points.
  if (f->>'has_batt')::boolean and not (f->>'shared')::boolean then
    if spread is not null then
      if spread >= 10 then
        s.drift_run_start := coalesce(s.drift_run_start, p_ts);
        s.drift_clear_at := null;
        s.drift_banks := (select jsonb_agg(jsonb_build_object('name', coalesce(nullif(m.alias, ''), 'Inverter ' || r.sn),
                                                              'chargePct', round(r.batt_soc)::int) order by m.ord nulls last, r.sn)
                            from public.readings r left join plants.meta_info m on m.sn = r.sn
                           where r.plant_id = p_plant and r.ts = p_ts and r.batt_soc between 1 and 100);
        if not s.drift and p_ts - s.drift_run_start >= 3600 then
          s.drift := true; s.drift_since := s.drift_run_start; s.drift_n := 1; s.drift_sent_at := now();
          perform private.email_enqueue_plant(p_plant, 'bank_drift', 'bank_drift:' || p_plant || ':' || s.drift_since || ':1',
            jsonb_build_object('since', s.drift_since, 'banks', s.drift_banks));
        end if;
      else
        s.drift_run_start := null;
        if s.drift and spread < 8 then
          s.drift_clear_at := coalesce(s.drift_clear_at, p_ts);
          if p_ts - s.drift_clear_at >= 900 then
            perform private.email_enqueue_plant(p_plant, 'bank_drift_back', 'bank_drift_back:' || p_plant || ':' || s.drift_since,
              jsonb_build_object('since', s.drift_since, 'at', s.drift_clear_at,
                'banks', (select jsonb_agg(jsonb_build_object('name', coalesce(nullif(m.alias, ''), 'Inverter ' || r.sn),
                                                              'chargePct', round(r.batt_soc)::int) order by m.ord nulls last, r.sn)
                            from public.readings r left join plants.meta_info m on m.sn = r.sn
                           where r.plant_id = p_plant and r.ts = p_ts and r.batt_soc between 1 and 100)),
              'bank_drift:' || p_plant || ':' || s.drift_since || ':1');
            s.drift := false; s.drift_clear_at := null;
          end if;
        elsif s.drift then
          s.drift_clear_at := null;
        end if;
      end if;
    end if;
  elsif s.drift or s.drift_run_start is not null then
    s.drift := false; s.drift_run_start := null; s.drift_clear_at := null;
  end if;

  s.stepped_ts := p_ts;
  update private.plant_alert_state set
    grid_on = s.grid_on, grid_since = s.grid_since, grid_off_key = s.grid_off_key,
    grid_run_on = s.grid_run_on, grid_run_n = s.grid_run_n, grid_run_start = s.grid_run_start,
    last_dev = s.last_dev, stale = s.stale, stale_key = s.stale_key, stale_clear_at = s.stale_clear_at,
    hot = s.hot, hot_since = s.hot_since, hot_temp = s.hot_temp, hot_at = s.hot_at, hot_sent_at = s.hot_sent_at, hot_n = s.hot_n,
    hot_run_n = s.hot_run_n, hot_clear_at = s.hot_clear_at,
    drift = s.drift, drift_run_start = s.drift_run_start, drift_since = s.drift_since, drift_banks = s.drift_banks,
    drift_sent_at = s.drift_sent_at, drift_n = s.drift_n, drift_clear_at = s.drift_clear_at, stepped_ts = s.stepped_ts
  where plant_id = p_plant;
end $function$;

CREATE OR REPLACE FUNCTION private.first_load_continue()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  p bigint;
  rid bigint;                                                             -- 0235
  has_net boolean := to_regclass('net._http_response') is not null;      -- 0235
begin
  for p in
    -- SOLAR-378: up to 50 plants waiting for a refill, oldest first.
    with taken as (
      delete from private.refill_queue q
       where q.plant_id in (select plant_id from private.refill_queue
                             order by queued_at limit 50 for update skip locked)
      returning q.plant_id
    )
    select plant_id from taken
    union
    select pc.plant_id from plants.settings pc
     where pc.backfill_next is not null
        or (pc.temp_next is not null and pc.temp_next < public.today_tz(plants.tz(pc.plant_id)) - 1)
  loop
    -- 0235: the last run on this plant is still going.
    if has_net and exists (
         select 1 from private.recover_kicks k
          where k.plant_id = p and k.at > now() - interval '155 seconds'
            and not exists (select 1 from net._http_response r where r.id = k.request_id)) then
      -- A refill taken off the queue waits for the next turn, not the 6-hourly run.
      insert into private.refill_queue (plant_id) values (p) on conflict do nothing;
      continue;
    end if;
    rid := net.http_post(                                                 -- 0235: keep the id
      url := private.functions_url() || '/recover?plant=' || p,               -- 0280
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
        'Content-Type', 'application/json'),
      body := '{}'::jsonb,
      timeout_milliseconds := 150000);
    insert into private.recover_kicks (plant_id, request_id) values (p, rid)   -- 0235
      on conflict (plant_id) do update set request_id = excluded.request_id, at = now();
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION private.grid_minutes(p_plant bigint, p_from bigint, p_to bigint)
 RETURNS TABLE(ts bigint, present boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with voters as (
    select r.ts, r.grid_volt_v, r.device_time
      from public.readings r
     where r.plant_id = p_plant
       and r.ts >= p_from and r.ts < p_to
       and r.grid_volt_v is not null
       and (r.grid_volt_v <> 0 or r.device_time is not null)
  ),
  newest as (
    select v.ts, max(v.device_time) as dt from voters v group by v.ts
  ),
  ours as (
    select v.ts, bool_or(public.grid_live(v.grid_volt_v)) as present
      from voters v join newest n on n.ts = v.ts
     where v.device_time is not distinct from n.dt
     group by v.ts
  ),
  -- 0167: the brand's history for the minutes we have no reading for
  hist as (
    select (h.ts / 60) * 60 as ts, bool_or(h.grid_fac_hz >= 40) as present
      from public.inverter_history h
     where h.plant_id = p_plant
       and h.ts >= p_from and h.ts < p_to
       and h.grid_fac_hz is not null
       and coalesce((select c.has_grid from plants.settings c where c.plant_id = p_plant), true)
     group by 1
  )
  select o.ts, o.present from ours o
  union all
  select h.ts, h.present from hist h where not exists (select 1 from ours o where o.ts = h.ts)
$function$;

CREATE OR REPLACE FUNCTION private.grid_off_update_all()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare p bigint; out jsonb := '{}'::jsonb;
begin
  for p in select distinct plant_id from plants.user_plants loop
    out := out || jsonb_build_object(p::text, private.grid_off_update(p));
  end loop;
  return out;
end $function$;

CREATE OR REPLACE FUNCTION private.history_done(c plant_config)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select c.backfill_next is null
     and (c.temp_next is null or c.temp_next >= public.today_tz(plants.tz(c.plant_id)) - 1)
$function$;

CREATE OR REPLACE FUNCTION private.login_copies(p_account uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  select o.id
    from plants.logins a
    join plants.logins o
      on o.brand = a.brand and lower(o.username) = lower(a.username)
   where a.id = p_account and o.id <> p_account and o.status <> 'disabled'
$function$;

CREATE OR REPLACE FUNCTION private.login_lock(p_logins uuid[], p_status text, p_user uuid DEFAULT NULL::uuid, p_plants bigint[] DEFAULT '{}'::bigint[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
declare
  x uuid;
  moving uuid[];
begin
  foreach x in array array(select distinct l from unnest(p_logins) l where l is not null order by 1) loop
    perform pg_advisory_xact_lock(1, hashtext(x::text));
  end loop;
  moving := case when p_status is null then '{}'::uuid[]
                 else array(select sa.id from plants.logins sa
                             where sa.id = any (p_logins) and sa.status is distinct from p_status) end;
  perform 1 from billing.accounts a
   where a.id in (select bl.account from plants.logins bl where bl.id = any (moving))
      or a.user_id = p_user
   order by a.id for update;
  perform billing.lock_plants(array(select lp.plant from plants.login_plants lp where lp.login = any (moving))
                              || coalesce(p_plants, '{}'));
end $function$;

CREATE OR REPLACE FUNCTION private.plant_checks()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  p bigint;
  n int := 0;
  sign text;
begin
  for p in select x from public.live_plants() x
            where x % 10 = (floor(extract(epoch from now()) / 60))::bigint % 10 order by x loop
    begin perform public.plant_features_detect(p); exception when others then raise warning 'plant_features_detect %: %', p, sqlerrm; end;
    begin perform public.battery_banks_detect(p); exception when others then raise warning 'battery_banks_detect %: %', p, sqlerrm; end;
    if (select c.batt_positive_means from public.plant_config c where c.plant_id = p) is null then
      sign := (select b.batt_positive_means from plants.brands b where b.code = plants.brand_of(p));
      begin perform public.batt_sign_detect(p, coalesce(sign, 'discharging')); exception when others then raise warning 'batt_sign_detect %: %', p, sqlerrm; end;
    end if;
    n := n + 1;
  end loop;
  return jsonb_build_object('plants', n);
end $function$;

CREATE OR REPLACE FUNCTION private.plant_start_fill(p_plant bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare tz text;
begin
  -- After a wipe that is running now, never under it.
  perform pg_advisory_xact_lock(p_plant);
  delete from private.plant_wipe where plant_id = p_plant;
  if not exists (select 1 from plants.settings where plant_id = p_plant) then
    -- Linked stopped, so never seeded (plants.ts syncPlants). South Africa only;
    -- the seed sets the 60-day bookmarks.
    perform public.plant_config_seed(jsonb_build_array(jsonb_build_object('plant_id', p_plant)));
  else
    tz := plants.tz(p_plant);
    update public.plant_config
       set backfill_next = (now() at time zone tz)::date - 60,
           backfill_until = (now() at time zone tz)::date - 14,
           backfill_tries = 0,
           temp_next = (now() at time zone tz)::date - 60
     where plant_id = p_plant;
  end if;
  if p_plant not in (select public.live_plants()) then
    update public.plant_config set backfill_next = null, backfill_until = null, temp_next = null
     where plant_id = p_plant;
  end if;
  -- No readings counts from here (0174): the reading time kept from before the stop is old.
  insert into private.plant_alert_state (plant_id, started_at) values (p_plant, extract(epoch from now())::bigint)
  on conflict (plant_id) do update set started_at = excluded.started_at;
  perform public.plant_bootstrap_kick(p_plant);
end $function$;

CREATE OR REPLACE FUNCTION private.poll_shards(p_per_shard integer DEFAULT 25)
 RETURNS TABLE(shard integer, shards integer, delay_ms integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_temp'
AS $function$
  with n as (
    select greatest(1, ceil(count(*)::numeric / greatest(p_per_shard, 1)))::int as shards
      from plants.login_info
     where status = 'ok'
  )
  -- 0, 2 or 4 s past the minute (SOLAR-681 R21): spread enough for the start, and every
  -- reading saved before its page asks at 12-42 s (it was 0/10/20 s)
  select s.i, n.shards, (s.i % 3) * 2000
    from n, generate_series(0, n.shards - 1) as s(i)
$function$;

CREATE OR REPLACE FUNCTION private.purge_plant(p_plant bigint, p_wait boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  out jsonb;
  n bigint;
begin
  if billing.is_live() then return null; end if;
  if p_wait then
    perform pg_advisory_xact_lock(p_plant);
  elsif not pg_try_advisory_xact_lock(p_plant) then
    return null;
  end if;
  if not exists (select 1 from private.plant_purge where plant_id = p_plant) then
    return null;
  end if;
  if exists (select 1 from plants.user_plants where plant_id = p_plant) then
    delete from private.plant_purge where plant_id = p_plant;
    return jsonb_build_object('skipped', 'linked again');
  end if;

  out := private.plant_readings_delete(p_plant);
  out := out || plants.purge(p_plant);   -- this part's rows: settings, their log, inverters, meta (R1, R2)
  delete from private.plant_alert_state    where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_alert_state', n);
  delete from private.inverter_alert_state where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_alert_state', n);
  delete from private.string_alert_state   where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('string_alert_state', n);
  delete from private.plant_wipe           where plant_id = p_plant;
  delete from private.plant_purge          where plant_id = p_plant;
  return out;
end $function$;

CREATE OR REPLACE FUNCTION private.refresh_store(p_account uuid, p_refresh text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'vault', 'pg_temp'
AS $function$
declare
  old_id uuid;
  new_id uuid;
begin
  -- Vault secret names are unique, so the old one must go before the new one is
  -- created under the same name. Same transaction: there is never a moment with
  -- no secret on file.
  select refresh_secret_id into old_id from plants.logins where id = p_account;
  if old_id is not null then
    update plants.logins set refresh_secret_id = null where id = p_account;
    delete from vault.secrets where id = old_id;
  end if;
  new_id := vault.create_secret(p_refresh, 'brand_refresh_' || p_account::text,
                                'brand refresh token for login ' || p_account::text);
  update plants.logins set refresh_secret_id = new_id where id = p_account;
end $function$;

CREATE OR REPLACE FUNCTION private.reports_due(p_now timestamp with time zone)
 RETURNS TABLE(user_id uuid, plant_id bigint, d date, period text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with loc as (
    select pu.user_id, pu.plant_id, timezone(public.plant_tz(pu.plant_id), p_now) as t,
           timezone(public.plant_tz(pu.plant_id), pu.linked_at)::date as linked_on
      from plants.user_plants pu
  )
  select l.user_id, l.plant_id, l.t::date, p.period
    from loc l, lateral (values ('week', 3), ('month', 7), ('year', 30)) p(period, min_days)
   where extract(hour from l.t) >= 7
     and case p.period when 'week'  then extract(isodow from l.t) = 1
                       when 'month' then extract(day from l.t) = 1
                       else extract(day from l.t) = 1 and extract(month from l.t) = 1 end
     -- the days from linked_on to the day before the report: at least min_days
     and l.linked_on <= l.t::date - p.min_days
$function$;

CREATE OR REPLACE FUNCTION private.rollup_partition(p_parent text, p_child text, p_from bigint DEFAULT NULL::bigint, p_to bigint DEFAULT NULL::bigint, p_plant bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare n bigint; f text := '';
begin
  if (p_from is null) <> (p_to is null) then
    raise exception 'rollup_partition: give both p_from and p_to, or neither';
  end if;
  if p_from is not null then
    -- a slice never cuts a 5-minute bucket: on conflict do nothing would keep half of it
    if p_from % 300 <> 0 or p_to % 300 <> 0 then
      raise exception 'rollup_partition: % to % is not on 5-minute bounds', p_from, p_to;
    end if;
    f := format(' and ts >= %s and ts < %s', p_from, p_to);
  end if;
  if p_plant is not null then
    f := f || format(' and plant_id = %s', p_plant);
  end if;
  if p_parent = 'readings' then
    execute format($q$
      insert into public.readings_5m (plant_id, sn, ts, n, n_fresh, n_carried, status_last, status_kinds, relay_last, relay_open_min, grid_off_min, pv_w_avg, pv_w_min, pv_w_max, batt_w_avg, batt_w_min, batt_w_max, batt_power_w_avg, batt_power_w_min, batt_power_w_max, grid_w_avg, grid_w_min, grid_w_max, load_w_avg, load_w_min, load_w_max, output_w_avg, output_w_min, output_w_max, batt2_power_w_avg, batt2_power_w_min, batt2_power_w_max, batt_current_a_avg, batt_current_a_min, batt_current_a_max, batt2_current_a_avg, batt2_current_a_min, batt2_current_a_max, batt_voltage_v_avg, batt_voltage_v_min, batt_voltage_v_max, batt2_voltage_v_avg, batt2_voltage_v_min, batt2_voltage_v_max, grid_volt_v_avg, grid_volt_v_min, grid_volt_v_max, grid_volt_l2_v_avg, grid_volt_l2_v_min, grid_volt_l2_v_max, grid_volt_l3_v_avg, grid_volt_l3_v_min, grid_volt_l3_v_max, output_volt_v_avg, output_volt_v_min, output_volt_v_max, output_volt_l2_v_avg, output_volt_l2_v_min, output_volt_l2_v_max, output_volt_l3_v_avg, output_volt_l3_v_min, output_volt_l3_v_max, batt_soc_avg, batt_soc_min, batt_soc_max, batt2_soc_avg, batt2_soc_min, batt2_soc_max, batt_temp_c_avg, batt_temp_c_min, batt_temp_c_max, batt2_temp_c_avg, batt2_temp_c_min, batt2_temp_c_max, grid_freq_hz_min, grid_freq_hz_max, load_freq_hz_min, load_freq_hz_max, output_freq_hz_min, output_freq_hz_max, grid_pf_avg, grid_in_w_avg, grid_out_w_avg, batt_pos_w_avg, batt_neg_w_avg, pv_today_kwh, pv_total_kwh, batt_chg_today_kwh, batt_dischg_today_kwh, batt_chg_total_kwh, batt_dischg_total_kwh, grid_import_today_kwh, grid_export_today_kwh, grid_import_total_kwh, grid_export_total_kwh, load_today_kwh, load_total_kwh)
      select plant_id, sn, (ts / 300) * 300,
           count(*),
           count(*) filter (where device_time is not null and not coalesce(carried, false)),
           count(*) filter (where carried),
           (array_agg(status order by ts desc))[1],
           count(distinct status),
           (array_agg(grid_relay_status order by ts desc))[1],
           count(*) filter (where grid_relay_status = '0'),
           count(*) filter (where device_time is not null and grid_volt_v is not null and not public.grid_live(grid_volt_v)),
           avg(pv_w),
           min(pv_w),
           max(pv_w),
           avg(batt_w),
           min(batt_w),
           max(batt_w),
           avg(batt_power_w),
           min(batt_power_w),
           max(batt_power_w),
           avg(grid_w),
           min(grid_w),
           max(grid_w),
           avg(load_w),
           min(load_w),
           max(load_w),
           avg(output_w),
           min(output_w),
           max(output_w),
           avg(batt2_power_w),
           min(batt2_power_w),
           max(batt2_power_w),
           avg(batt_current_a),
           min(batt_current_a),
           max(batt_current_a),
           avg(batt2_current_a),
           min(batt2_current_a),
           max(batt2_current_a),
           avg(batt_voltage_v),
           min(batt_voltage_v),
           max(batt_voltage_v),
           avg(batt2_voltage_v),
           min(batt2_voltage_v),
           max(batt2_voltage_v),
           avg(grid_volt_v),
           min(grid_volt_v),
           max(grid_volt_v),
           avg(grid_volt_l2_v),
           min(grid_volt_l2_v),
           max(grid_volt_l2_v),
           avg(grid_volt_l3_v),
           min(grid_volt_l3_v),
           max(grid_volt_l3_v),
           avg(output_volt_v),
           min(output_volt_v),
           max(output_volt_v),
           avg(output_volt_l2_v),
           min(output_volt_l2_v),
           max(output_volt_l2_v),
           avg(output_volt_l3_v),
           min(output_volt_l3_v),
           max(output_volt_l3_v),
           avg(nullif(batt_soc, 0)),
           min(nullif(batt_soc, 0)),
           max(nullif(batt_soc, 0)),
           avg(nullif(batt2_soc, 0)),
           min(nullif(batt2_soc, 0)),
           max(nullif(batt2_soc, 0)),
           avg(case when batt_temp_c < -50 then null else batt_temp_c end),
           min(case when batt_temp_c < -50 then null else batt_temp_c end),
           max(case when batt_temp_c < -50 then null else batt_temp_c end),
           avg(case when batt2_temp_c < -50 then null else batt2_temp_c end),
           min(case when batt2_temp_c < -50 then null else batt2_temp_c end),
           max(case when batt2_temp_c < -50 then null else batt2_temp_c end),
           min(grid_freq_hz),
           max(grid_freq_hz),
           min(load_freq_hz),
           max(load_freq_hz),
           min(output_freq_hz),
           max(output_freq_hz),
           avg(grid_pf),
           avg(greatest(grid_w, 0)),
           avg(greatest(-grid_w, 0)),
           avg(greatest(batt_w, 0)),
           avg(greatest(-batt_w, 0)),
           (array_agg(pv_today_kwh order by ts desc) filter (where pv_today_kwh is not null))[1],
           (array_agg(pv_total_kwh order by ts desc) filter (where pv_total_kwh <> 0))[1],
           (array_agg(batt_chg_today_kwh order by ts desc) filter (where batt_chg_today_kwh is not null))[1],
           (array_agg(batt_dischg_today_kwh order by ts desc) filter (where batt_dischg_today_kwh is not null))[1],
           (array_agg(batt_chg_total_kwh order by ts desc) filter (where batt_chg_total_kwh <> 0))[1],
           (array_agg(batt_dischg_total_kwh order by ts desc) filter (where batt_dischg_total_kwh <> 0))[1],
           (array_agg(grid_import_today_kwh order by ts desc) filter (where grid_import_today_kwh is not null))[1],
           (array_agg(grid_export_today_kwh order by ts desc) filter (where grid_export_today_kwh is not null))[1],
           (array_agg(grid_import_total_kwh order by ts desc) filter (where grid_import_total_kwh <> 0))[1],
           (array_agg(grid_export_total_kwh order by ts desc) filter (where grid_export_total_kwh <> 0))[1],
           (array_agg(load_today_kwh order by ts desc) filter (where load_today_kwh is not null))[1],
           (array_agg(load_total_kwh order by ts desc) filter (where load_total_kwh <> 0))[1]
        from public.%I
       where plant_id is not null%s
       group by plant_id, sn, (ts / 300) * 300
      on conflict do nothing$q$, p_child, f);
  elsif p_parent = 'strings' then
    execute format($q$
      insert into public.strings_5m (plant_id, sn, no, ts, n, volt_v_avg, volt_v_min, volt_v_max, current_a_avg, current_a_min, current_a_max, power_w_avg, power_w_min, power_w_max, today_kwh)
      select plant_id, sn, no, (ts / 300) * 300,
           count(*),
           avg(volt_v),
           min(volt_v),
           max(volt_v),
           avg(current_a),
           min(current_a),
           max(current_a),
           avg(power_w),
           min(power_w),
           max(power_w),
           (array_agg(today_kwh order by ts desc) filter (where today_kwh <> 0))[1]
        from public.%I
       where plant_id is not null%s
       group by plant_id, sn, no, (ts / 300) * 300
      on conflict do nothing$q$, p_child, f);
  else
    raise exception 'rollup_partition: unknown parent %', p_parent;
  end if;
  get diagnostics n = row_count;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION private.setup_steps_open(p_plant bigint)
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select array_remove(array[
           case when not coalesce(c.tariff_import > 0, false) then 'rate' end,
           case when c.has_battery is distinct from false and not coalesce(c.battery_kwh > 0, false) then 'size' end,
           case when c.has_battery is distinct from false and not coalesce(c.battery_reserve_confirmed, false)
                 and coalesce(c.battery_reserve_pct, 20) = 20 then 'reserve' end,
           case when not coalesce(c.system_kwp > 0, false) then 'panels' end], null)
    from (select 1) one
    left join plants.settings c on c.plant_id = p_plant
$function$;

CREATE OR REPLACE FUNCTION private.username_logins(p_user uuid, p_username text)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
  select coalesce(array_agg(sa.id order by sa.id), '{}') from plants.logins sa
   where lower(sa.username) = lower(p_username)
     and ((sa.user_id = p_user and sa.kind = 'login') or sa.status <> 'disabled')
$function$;

CREATE OR REPLACE FUNCTION public.account_access_set(p_account uuid, p_access text, p_expires bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
begin
  perform private.login_lock(array(select p_account union select private.login_copies(p_account)), 'ok');
  update plants.logins
     set access_token = p_access, access_expires_at = p_expires, last_ok_at = now(), last_error = null
   where id = p_account;
  update plants.logins
     set access_token = p_access, access_expires_at = p_expires, status = 'ok', last_error = null
   where id in (select private.login_copies(p_account));
end $function$;

CREATE OR REPLACE FUNCTION public.account_by_username(p_username text)
 RETURNS TABLE(id uuid, user_id uuid, status text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  select id, user_id, status from plants.logins where username = p_username
$function$;

CREATE OR REPLACE FUNCTION public.account_disable(p_account uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'vault', 'pg_temp'
AS $function$
declare sid uuid;
begin
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  select refresh_secret_id into sid from plants.logins where id = p_account;
  update plants.logins
     set status = 'disabled', access_token = null, access_expires_at = null, refresh_secret_id = null
   where id = p_account;
  if sid is not null then delete from vault.secrets where id = sid; end if;
end $function$;

CREATE OR REPLACE FUNCTION public.account_mark(p_account uuid, p_status text, p_error text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
begin
  -- the words before SOLAR-681 R4, from a poll function deployed before this database
  p_status := case p_status when 'active' then 'ok' when 'needs_relink' then 'needs_reconnect' else p_status end;
  -- the copies' status moves only with a dead sign-in
  perform private.login_lock(array(select p_account union select private.login_copies(p_account)
                                    where p_status = 'needs_reconnect'), p_status);
  -- One row for the account poll was working on; its copies die with it below.
  insert into plants.login_events (account_id, event, reason, last_ok_at, access_expires_at)
  select id, 'died', p_error, last_ok_at, access_expires_at
    from plants.logins
   where id = p_account and p_status = 'needs_reconnect';
  update plants.logins set status = p_status, last_error = p_error where id = p_account;
  -- A dead sign-in is dead for every copy holding that same refresh token. A copy
  -- with a different (newer) token, or a row with none, keeps its own status, and
  -- other errors stay with the row.
  update plants.logins set status = p_status, last_error = p_error
   where p_status = 'needs_reconnect' and id in (select private.login_copies(p_account))
     and public.account_refresh_get(id) = public.account_refresh_get(p_account);
end $function$;

CREATE OR REPLACE FUNCTION public.account_refresh_get(p_account uuid)
 RETURNS text
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'private', 'vault', 'pg_temp'
AS $function$
  select ds.decrypted_secret
    from plants.logins a
    join vault.decrypted_secrets ds on ds.id = a.refresh_secret_id
   where a.id = p_account
$function$;

CREATE OR REPLACE FUNCTION public.account_upsert(p_user uuid, p_username text, p_access text, p_expires bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
begin
  -- the link without a refresh token yet (the bootstrap login): link_login_live's path
  if not plants.link_allowed(p_user, plants.brand_for_username(p_username), p_username) then
    raise exception 'one login' using errcode = '22023';
  end if;
  return plants.link_login(billing.account_of(p_user), plants.brand_for_username(p_username), p_username, '[]'::jsonb, now(), 'owner',
                           null, p_access, p_expires);
end
$function$;

CREATE OR REPLACE FUNCTION public.admin_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if auth.uid() is null or not exists (select 1 from private.admins where user_id = auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'at', now(),
    'users', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'email', u.email,
               'provider', u.raw_app_meta_data->>'provider',
               'createdAt', u.created_at,
               'lastSignInAt', u.last_sign_in_at,
               'plants', (select count(*) from plants.user_plants pu where pu.user_id = u.id),
               'admin', exists (select 1 from private.admins a where a.user_id = u.id)
             ) order by u.created_at), '[]'::jsonb)
        from auth.users u),
    'plants', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'plantId', pu.plant_id,
               'name', pu.plant_name,
               'email', u.email,
               'linkedAt', pu.linked_at,
               'inverters', (select count(*) from plants.meta_info m where m.plant_id = pu.plant_id),
               'lastTs', (select a.ts from public.agg_minute a
                           where a.plant_id = pu.plant_id order by a.ts desc limit 1)
             ) order by u.email, pu.plant_id), '[]'::jsonb)
        from plants.user_plants pu
        join auth.users u on u.id = pu.user_id),
    'logins', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'email', u.email,
               'sunsynkUser', s.username,   -- reuse-check: allow (the admin page reads this key)
               'status', s.status,
               'linkedAt', s.linked_at,
               'lastOkAt', s.last_ok_at,
               'lastError', left(s.last_error, 300)
             ) order by u.email, s.linked_at), '[]'::jsonb)
        from plants.login_info s
        join auth.users u on u.id = s.user_id),
    'errors', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'at', e.at,
               'email', u.email,
               'plantId', e.plant_id,
               'version', e.app_version,
               'page', e.page,
               'message', left(e.message, 300)
             ) order by e.at desc), '[]'::jsonb)
        from (select * from public.client_errors order by at desc limit 50) e
        left join auth.users u on u.id = e.user_id)
  );
end $function$;

CREATE OR REPLACE FUNCTION public.api_account_delete()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'vault', 'pg_temp'
AS $function$
declare
  uid uuid := auth.uid();
  acc record;
  gone jsonb;
  orphans bigint[];
begin
  -- 0247's lock order, kept: the billing-run lock, then the lock of each login its links hang on
  -- (its own and the share login), then the link rows, then the account (billing.delete_account).
  -- A reconnect, a claim of a lapsed share and the poller's share update take them in this order;
  -- the other way round deadlocks (scripts/billing-lock-test.mjs)
  perform pg_advisory_xact_lock_shared(3, 0);
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  for acc in select x.id from (select id from plants.login_info where user_id = uid
                               union select account_id from plants.user_plants where user_id = uid and account_id is not null) x
              order by x.id loop
    perform pg_advisory_xact_lock(1, hashtext(acc.id::text));
  end loop;
  perform 1 from plants.list_info lp join plants.login_info l on l.id = lp.login
   where l.user_id = uid order by lp.login, lp.plant for update of lp;
  -- the logins' secrets first: billing.delete_account's cascade takes the login rows with it
  perform plants.user_secrets_clear(uid);
  gone := case when exists (select 1 from billing.accounts where user_id = uid)
               then billing.delete_account((select id from billing.accounts where user_id = uid))
               else jsonb_build_object('unprotected', '[]'::jsonb) end;
  orphans := array(select (x)::bigint from jsonb_array_elements_text(gone->'unprotected') x);
  perform plants.user_logins_delete(uid);   -- its lists and events go with it; claims went with the account
  insert into public.email_queue (to_email, kind, key, priority)
  select email, 'account_deleted', 'account_deleted:' || uid, 1 from auth.users where id = uid and email is not null
  on conflict do nothing;
  delete from public.profiles where user_id = uid;
  delete from auth.users where id = uid;
  return jsonb_build_object('deleted', true, 'plantsRemoved', coalesce(cardinality(orphans), 0));
end $function$;

CREATE OR REPLACE FUNCTION public.api_alerts(p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_switch text DEFAULT NULL::text, p_unread boolean DEFAULT false, p_before bigint DEFAULT NULL::bigint, p_before_ts timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with raw as (
    -- every alert the user can still see: plants still linked, and readable (0204)
    select q.id, q.kind, q.key, q.plant_id, pu.plant_name, q.read_at, q.created_at, q.data, q.status,
           -- one login stopping (or coming back) writes a row per plant: one group (0232)
           -- (rows from before 0158 have no since: each stays its own)
           coalesce(case when q.kind in ('needs_relink', 'relinked') and q.data ? 'since'
                         then q.kind || ':' || coalesce(q.data->>'account', '') || ':' || (q.data->>'since') end,
                    q.id::text) grp
      from public.email_queue q
      join plants.user_plants pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid() and private.is_alert(q.kind)
       and q.plant_id in (select public.my_plant_ids())),
  a as (
    -- each group shows once, on its emailed row when readable; read when every row is
    select z.* from (
      select r.*, jsonb_agg(r.id) over w ids, bool_and(r.read_at is not null) over w is_read,
             row_number() over (partition by r.grp order by r.status = 'skipped', r.id) rn
        from raw r window w as (partition by r.grp)) z
     where z.rn = 1),
  e as (
    select s.* from a s
     where (p_from is null or s.created_at >= p_from)
       and (p_switch is null or private.alert_group(s.kind) = p_switch)
       and (p_before is null or (s.created_at, s.id) < (p_before_ts, p_before))
       and (not p_unread or not s.is_read)
     order by s.created_at desc, s.id desc
     limit greatest(1, least(p_limit, 200)) + 1),
  shown as (select * from e order by created_at desc, id desc limit greatest(1, least(p_limit, 200))),
  -- when each "back" kind was first sent, by anyone; Reconnected exists from 0158 on
  firsts as (select f.kind, min(f.at) at from (
               select q.kind, q.created_at at from public.email_queue q
                where q.kind in (select private.alert_back_kind(k.kind) from shown k)
               union all select 'relinked', timestamptz '2026-11-07 00:00+02') f
              group by f.kind)
  select jsonb_build_object(
    'more', (select count(*) from e) > greatest(1, least(p_limit, 200)),
    'unread', (select count(*) from a where not is_read),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'ts', s.created_at, 'kind', s.kind, 'plant', s.plant_id, 'plantName', s.plant_name,
        'read', s.is_read,
        'ids', s.ids,
        'open', coalesce(private.is_alert(private.alert_back_kind(s.kind)), false)
                and not exists (select 1 from public.email_queue b where b.user_id = auth.uid() and b.pair_key = s.key)
                and coalesce(s.created_at >= (select f.at from firsts f where f.kind = private.alert_back_kind(s.kind)), false)
                and not exists (select 1 from public.email_queue l where l.user_id = auth.uid() and l.plant_id = s.plant_id
                                  and l.kind = s.kind and l.created_at > s.created_at))
        -- the facts; the app writes the words (text.ts alertLine, 0264). 0265: no old words
        || jsonb_build_object('switch', private.alert_group(s.kind),
             'data', private.grid_notice_data(s.plant_id, s.kind, s.data),                                -- 0167
             'created', extract(epoch from s.created_at), 'tz', public.plant_tz(s.plant_id))
        order by s.created_at desc, s.id desc) from shown s),
      '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION public.api_balance(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  now_s as (select extract(epoch from now())::bigint as t),
  -- newest first, take one: max(ts) read every month of readings, because the plant id
  -- comes from pl and the planner can't use the index to stop early (SOLAR-35)
  latest_ts as (select (select ts from public.readings where plant_id = (select id from pl) and batt_soc is not null order by ts desc limit 1) as ts),
  -- one shared pack counts as one bank however many inverters read it (0042)
  nbanks as (select case when (select battery_banks from plants.settings where plant_id = (select id from pl)) = 'shared' then least(1, count(distinct r.sn)) else count(distinct r.sn) end as n
               from public.readings r, latest_ts where r.plant_id = (select id from pl) and r.ts = latest_ts.ts and r.batt_soc between 1 and 100),
  bal as (
    select r.ts, max(r.batt_soc) - min(r.batt_soc) as socspread, max(r.batt_voltage_v) - min(r.batt_voltage_v) as vspread
      from public.readings r, now_s
     where r.plant_id = (select id from pl) and r.ts >= now_s.t - 72 * 3600
       and r.batt_soc is not null and r.batt_soc between 1 and 100
     group by r.ts
    having count(distinct r.sn) >= 2 and (max(r.batt_soc) - min(r.batt_soc)) <= 25
  ),
  last_r as (select * from bal order by ts desc limit 1),
  win as (select count(*) >= 2 and (max(ts) - min(ts)) >= 9 * 60 as have_window, min(socspread) as min_spread from bal, now_s where bal.ts >= now_s.t - 600),
  spreads as (select (select round(socspread * 10) / 10 from last_r) as soc_spread, (select round(vspread * 100) / 100 from last_r) as v_spread),
  st as (
    select case when (select n from nbanks) < 2 then 'single'
                when s.soc_spread is null then 'unknown'
                when not coalesce(w.have_window, false) then 'balanced'
                when w.min_spread >= 5 then 'drifting' when w.min_spread >= 3 then 'watch' else 'balanced' end as status,
           case when (select n from nbanks) < 2 then 'single'
                when s.soc_spread is null then 'unknown'
                when s.soc_spread < 3 then 'balanced' when s.soc_spread < 5 then 'watch' else 'drifting' end as live_band,
           s.soc_spread, s.v_spread
      from spreads s, win w
  ),
  today_lo as (select public.day_start_epoch_tz(public.today_tz((select tz from pz)), (select tz from pz)) as lo),
  health as (
    select (select batt_temp_c from public.readings where plant_id = (select id from pl) and batt_temp_c > 0 and batt_temp_c < 80 order by ts desc limit 1) as temp_c,
           (select coalesce(round(sum(case when soc >= 98 then 1 else 0 end) / 60.0, 1), 0)
              from public.agg_minute, today_lo where plant_id = (select id from pl) and ts >= today_lo.lo and ts < today_lo.lo + 86400) as hrs_full
  )
  select jsonb_build_object(
    'banks', coalesce((select jsonb_agg(jsonb_build_object('sn', r.sn, 'soc', r.batt_soc, 'voltage', r.batt_voltage_v, 'current', r.batt_current_a) order by r.sn)
              from public.readings r, latest_ts where r.plant_id = (select id from pl) and r.ts = latest_ts.ts), '[]'::jsonb),
    'bankCount', (select n from nbanks),
    'socSpread', st.soc_spread, 'vSpread', st.v_spread, 'status', st.status,
    'pending', st.live_band not in ('unknown', 'balanced', 'single') and st.status = 'balanced',
    'max24h', (select round(max(socspread) * 10) / 10 from bal, now_s where bal.ts >= now_s.t - 24 * 3600),
    'max72h', (select round(max(socspread) * 10) / 10 from bal),
    'samples', (select count(*) from bal),
    'tempC', h.temp_c, 'hrsAtFullToday', h.hrs_full,
    'tempHot', h.temp_c is not null and h.temp_c > 35,
    'stale', (select ts from latest_ts) is null or ((select t from now_s) - (select ts from latest_ts)) > 600)
  from st, health h
$function$;

CREATE OR REPLACE FUNCTION public.api_grid_today(p_plant bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with p as (select public.my_plant(p_plant) as id),
  z as (
    select p.id, plants.tz(p.id) as tz
      from p
  ),
  lo as (
    select z.id, extract(epoch from coalesce(p_date, (now() at time zone z.tz)::date)::timestamp at time zone z.tz)::bigint as t0,
           least(extract(epoch from (coalesce(p_date, (now() at time zone z.tz)::date) + 1)::timestamp at time zone z.tz)::bigint,
                 extract(epoch from now())::bigint + 60) as t1
      from z
  ),
  m as (
    select g.ts, g.present
      from lo, private.grid_minutes(lo.id, lo.t0, lo.t1) g
  ),
  v as (
    select ((r.ts - lo.t0) / 300)::int as b,
           avg(r.grid_volt_v) filter (where public.grid_live(r.grid_volt_v)) as volt
      from lo join public.readings r on r.plant_id = lo.id and r.ts >= lo.t0 and r.ts < lo.t1
     group by 1
  ),
  o as (
    select ((m.ts - lo.t0) / 300)::int as b, bool_or(not m.present) as off
      from m, lo
     group by 1
  )
  select jsonb_build_object(
    'buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'i', coalesce(v.b, o.b),
               'v', round(v.volt::numeric, 1),
               'off', coalesce(o.off, false))
             order by coalesce(v.b, o.b))
        from v full join o on o.b = v.b), '[]'::jsonb),
    'offMinutes', (select count(*) from m where not m.present),
    'asOf', extract(epoch from now())::bigint                                    -- 0167
  )
$function$;

CREATE OR REPLACE FUNCTION public.api_inverter_history(p_date date DEFAULT NULL::date, p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  d as (select coalesce(p_date, public.today_tz((select tz from pz))) as day),
  lo as (select public.day_start_epoch_tz((select day from d), (select tz from pz)) as t0),
  raw as (
    select t.sn, ((t.ts - (select t0 from lo)) / 300)::int as bkt, t.ts, t.ac_c, t.dc_c, t.vac_v, t.fac_hz, t.grid_fac_hz
      from public.inverter_history t, lo
     where t.plant_id = (select id from pl) and t.ts >= lo.t0 and t.ts < lo.t0 + 86400
  ),
  fromraw as (
    select sn, bkt, count(*)::int as n, count(dc_c)::int as dcn,
           max(ac_c) as ac, max(dc_c) as dc, min(dc_c) as dcmin,
           min(vac_v) as vmin, max(vac_v) as vmax,
           (array_agg(vac_v order by ts desc) filter (where vac_v is not null))[1] as v,
           min(fac_hz) as fmin, max(fac_hz) as fmax,
           min(grid_fac_hz) as gmin, max(grid_fac_hz) as gmax
      from raw group by sn, bkt
  ),
  b as (
    select * from fromraw
    union all
    select f.sn, ((f.ts - (select t0 from lo)) / 300)::int, f.n::int, case when f.dc_max is null then 0 else f.n::int end,
           f.ac_max, f.dc_max, f.dc_min, f.vac_min, f.vac_max, f.vac_last,
           f.fac_min, f.fac_max, f.gfac_min, f.gfac_max
      from public.inverter_history_5m f, lo
     where f.plant_id = (select id from pl) and f.ts >= lo.t0 and f.ts < lo.t0 + 86400
       and not exists (select 1 from fromraw r
                        where r.sn = f.sn and r.bkt = ((f.ts - lo.t0) / 300)::int)
  ),
  sns as (
    select r.sn, coalesce(nullif(m.alias, ''), r.sn) as alias
      from (select distinct sn from b) r left join plants.meta_info m on m.sn = r.sn
  )
  select jsonb_build_object(
    'date', (select day from d)::text,
    'inverters', coalesce((select jsonb_agg(jsonb_build_object(
        'sn', s.sn, 'alias', s.alias,
        'dcFlat', (select sum(x.dcn) > 1 and min(x.dcmin) = max(x.dc) from b x where x.sn = s.sn),
        'last', (select public._hm(max(bkt)) from b x where x.sn = s.sn),
        'points', (select jsonb_agg(jsonb_build_object('time', public._hm(g.i),
                     'ac', x.ac, 'dc', x.dc, 'vmin', x.vmin, 'vmax', x.vmax, 'v', x.v,
                     'fmin', x.fmin, 'fmax', x.fmax, 'gmin', x.gmin, 'gmax', x.gmax) order by g.i)
                     from generate_series(0, 287) g(i) left join b x on x.sn = s.sn and x.bkt = g.i)
      ) order by s.alias) from sns s), '[]'::jsonb))
$function$;

CREATE OR REPLACE FUNCTION public.api_link_remove(p_account uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  uid uuid := auth.uid();
  acc uuid := billing.account_of(auth.uid(), false);
  l plants.logins;
  shared bigint[];
begin
  select * into l from plants.logins where id = p_account;
  if l.id is null or not (l.user_id = uid or (l.kind = 'share' and acc is not null
        and exists (select 1 from plants.claims c where c.account = acc))) then
    raise exception 'not your account' using errcode = '42501';
  end if;
  if l.kind = 'share' then
    -- the share login is not the owner's to remove: their claims on it go
    shared := array(select c.plant from plants.claims c where c.account = acc order by c.plant);
    delete from public.email_queue e where e.user_id = uid and e.plant_id = any (shared) and e.kind not like 'sunsynk_%';
    if cardinality(shared) > 0 then perform plants.unclaim(acc, shared); end if;
  else
    delete from public.email_queue e
     where e.user_id = uid
       and (e.plant_id in (select lp.plant from plants.login_plants lp where lp.login = p_account) and e.kind not like 'sunsynk_%'
            or e.key like 'needs_relink:' || p_account || ':%');
    perform plants.remove_login(acc, p_account);   -- private.inverters.account_id clears by its key
  end if;
  return jsonb_build_object('result', 'removed');
end
$function$;

CREATE OR REPLACE FUNCTION public.api_me()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'user', jsonb_build_object('id', auth.uid()),
    'prefs', coalesce((select prefs from public.profiles where user_id = auth.uid()), '{}'::jsonb),
    'plants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pu.plant_id, 'name', pu.plant_name, 'linkedAt', pu.linked_at,
               'config', (to_jsonb(c) - 'plant_id' - 'updated_by') || jsonb_build_object('timezone', plants.tz(pu.plant_id)))
             order by pu.linked_at, pu.plant_id)
        from plants.user_plants pu
        left join plants.settings c on c.plant_id = pu.plant_id
       where pu.user_id = auth.uid() and pu.plant_id in (select public.my_plant_ids())), '[]'::jsonb))
$function$;

CREATE OR REPLACE FUNCTION public.api_notifications()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with n as (
    select q.id, q.kind, q.plant_id, pu.plant_name, q.read_at, q.created_at, q.data
      from public.email_queue q
      join plants.user_plants pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid()
       and q.plant_id in (select public.my_plant_ids())
       and private.is_alert(q.kind)
       and q.created_at > now() - interval '30 days'
     order by q.created_at desc, q.id desc
     limit 300)
  select jsonb_build_object(
    'pinned', '[]'::jsonb,
    'unread', (select count(*) from n where read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'plant', plant_id, 'plantName', plant_name, 'read', read_at is not null) || jsonb_build_object(   -- 0265: no old words
        'data', data, 'created', extract(epoch from created_at), 'tz', public.plant_tz(plant_id),        -- 0264
        'switch', private.alert_group(kind))
        order by created_at desc, id desc) from n), '[]'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION public.api_overview(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  v_plant bigint := public.my_plant(p_plant);
  -- a variable, not now() in the query, so the planner cuts to the last 2 days
  v_floor bigint := extract(epoch from now())::bigint - 2 * 86400;
  v_ts    bigint;
  v_lo    bigint;  -- start of v_ts's local day: day counters count from here
  v_from  bigint;  -- the inverter list's window: the 2-day floor, or v_ts's day if older
  v_glo   bigint;  -- start of the plant's local today (not v_ts's day): grid_today counts from here
  v_out   jsonb;
begin
  select max(ts) into v_ts from public.readings where plant_id = v_plant and ts > v_floor;
  if v_ts is null then
    -- nothing in 2 days (outage, or a plant that stopped): look further back
    select max(ts) into v_ts from public.readings where plant_id = v_plant;
  end if;
  v_lo := public.day_start_epoch_tz((to_timestamp(v_ts) at time zone public.plant_tz(v_plant))::date, public.plant_tz(v_plant));
  v_from := least(v_floor, v_lo);
  -- a variable, not a CTE join: joined, the bound is unknown at plan time and the
  -- scan ran 18 ms instead of 2 (measured 2026-11-24)
  v_glo := public.day_start_epoch_tz(public.today_tz(public.plant_tz(v_plant)), public.plant_tz(v_plant));

  with pl as (select v_plant as id),
  cfg as (select * from public.plant_cfg(v_plant)),
  -- each known inverter's own last row in the window (SOLAR-555). An inverter the poller
  -- left out of the newest minute (SOLAR-296) keeps its day totals and its readAt; only
  -- the live figures below are limited to rows at v_ts. A row from before v_lo (silent
  -- since yesterday) lists the inverter but adds 0 to today's counters. Bounds are
  -- variables, not a join to a CTE, so each probe opens only the window's partitions
  -- (sn_ts index).
  r as (
    select x.*, x.ts >= v_lo as is_today from plants.inverter_info i
      cross join lateral (select rd.* from public.readings rd
                           where rd.sn = i.sn and rd.plant_id = v_plant and rd.ts >= v_from and rd.ts <= v_ts
                           order by rd.ts desc limit 1) x
     where i.plant_id = v_plant
  ),
  st as (
    select s.sn, jsonb_agg(jsonb_build_object('id', null, 'no', s.no, 'power', s.power_w, 'voltage', s.volt_v, 'current', s.current_a,
             'today', case when r.is_today then s.today_kwh else 0 end) order by s.no) as strings
      from r join public.strings s on s.plant_id = v_plant and s.sn = r.sn and s.ts = r.ts
     where s.ts >= v_from and s.ts <= v_ts
     group by s.sn
  ),
  inv as (
    select r.sn,
           jsonb_build_object(
             'sn', r.sn, 'alias', coalesce(m.alias, r.sn), 'model', m.model, 'status', r.status, 'gsn', m.gsn,
             'soft', m.soft_ver, 'hmi', m.hmi_ver, 'commType', m.comm_type,
             -- when the inverter took this reading, epoch seconds; a 5-minute logger can be minutes behind (0075)
             -- guarded: one malformed device_time must not take the whole snapshot down with a cast error
             'readAt', case when r.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
                         then extract(epoch from (r.device_time::timestamp at time zone public.plant_tz(v_plant)))::bigint end,
             'pv', jsonb_build_object('power', round(r.pv_w), 'today', case when r.is_today then r.pv_today_kwh else 0 end, 'total', r.pv_total_kwh, 'strings', coalesce(st.strings, '[]'::jsonb),
                     -- inputs the inverter reports, wired or not (0061); the page shows the rest as unused
                     'stringSlots', m.string_slots),
             'battery', jsonb_build_object(
               'power', round(abs(r.batt_w)), 'signedPower', round(r.batt_w),
               'status', case when r.batt_w > 5 then 'charging' when r.batt_w < -5 then 'discharging' else 'idle' end,
               'soc', r.batt_soc, 'voltage', r.batt_voltage_v, 'current', r.batt_current_a, 'temperature', r.batt_temp_c,
               'capacity', m.capacity_ah, 'numberOfBatteries', m.number_of_batteries,
               'todayCharged', case when r.is_today then r.batt_chg_today_kwh else 0 end,
               'todayDischarged', case when r.is_today then r.batt_dischg_today_kwh else 0 end,
               'totalCharged', r.batt_chg_total_kwh, 'totalDischarged', r.batt_dischg_total_kwh,
               -- second bank (the API's *2 fields), only when the firmware reports one (0042)
               'bank2', case when r.batt2_soc is not null then jsonb_build_object(
                 'soc', r.batt2_soc, 'voltage', r.batt2_voltage_v, 'current', r.batt2_current_a,
                 'power', r.batt2_power_w, 'temperature', r.batt2_temp_c) end),
             'grid', jsonb_build_object(
               'power', round(r.grid_w), 'direction', case when r.grid_w >= 0 then 'importing' else 'exporting' end,
               'todayImport', case when r.is_today then r.grid_import_today_kwh else 0 end,
               'todayExport', case when r.is_today then r.grid_export_today_kwh else 0 end,
               'totalImport', r.grid_import_total_kwh, 'totalExport', r.grid_export_total_kwh,
               'frequency', r.grid_freq_hz, 'powerFactor', r.grid_pf,
               'voltage', r.grid_volt_v, 'relay', r.grid_relay_status,
               -- one entry per phase this inverter reports (L1 [, L2, L3])
               'voltages', (select jsonb_agg(v) from unnest(array[r.grid_volt_v, r.grid_volt_l2_v, r.grid_volt_l3_v]) v where v is not null)),
             'load', jsonb_build_object('power', round(r.load_w), 'today', case when r.is_today then r.load_today_kwh else 0 end, 'total', r.load_total_kwh, 'frequency', r.load_freq_hz),
             'output', jsonb_build_object('power', round(r.output_w), 'voltage', r.output_volt_v, 'frequency', r.output_freq_hz,
               'voltages', (select jsonb_agg(v) from unnest(array[r.output_volt_v, r.output_volt_l2_v, r.output_volt_l3_v]) v where v is not null))) as snap,
           r.ts, r.pv_w, r.load_w, r.grid_w, r.batt_w, r.batt_soc,
           case when r.is_today then r.pv_today_kwh else 0 end as pv_today_kwh,
           case when r.is_today then r.grid_import_today_kwh else 0 end as grid_import_today_kwh,
           case when r.is_today then r.grid_export_today_kwh else 0 end as grid_export_today_kwh,
           r.grid_volt_v, r.grid_volt_l2_v, r.grid_volt_l3_v,
           coalesce(m.ord, 9999) as ord
      from r left join plants.meta_info m on m.sn = r.sn left join st on st.sn = r.sn
  ),
  -- live figures from the inverters in the newest minute only; day counters from every row
  totals as (
    select sum(round(pv_w)) filter (where ts = v_ts) as pv, sum(round(load_w)) filter (where ts = v_ts) as load,
           sum(round(grid_w)) filter (where ts = v_ts) as grid, sum(round(batt_w)) filter (where ts = v_ts) as batt,
           -- one shared pack: every inverter reads the same BMS, so take the first (master) rather than averaging copies
           case when (select battery_banks from cfg) = 'shared'
                then (select i.batt_soc from inv i where i.batt_soc > 0 and i.ts = v_ts order by i.ord, i.sn limit 1)
                else avg(batt_soc) filter (where batt_soc > 0 and ts = v_ts) end as soc,
           sum(pv_today_kwh) as today_pv, sum(grid_import_today_kwh) as today_imp, sum(grid_export_today_kwh) as today_exp,
           -- a phase that has dropped while another is live (three-phase only)
           bool_or(public.grid_live(grid_volt_v) and not public.grid_live(least(coalesce(grid_volt_l2_v, 999), coalesce(grid_volt_l3_v, 999)))) filter (where ts = v_ts) as phase_down
      from inv
  ),
  -- q_grid_present's rule on the rows already in r (same plant, same ts); calling
  -- it planned readings again with every partition
  gv as (select grid_volt_v, device_time from r where grid_volt_v is not null and ts = v_ts),
  gp as (
    select case when not exists (select 1 from gv) then null
                else (select bool_or(public.grid_live(v.grid_volt_v)) from gv v
                       where v.device_time is not distinct from (select max(device_time) from gv)) end as present
  ),
  -- q_day_agg's day and 5-minute blocks, grid only (0260)
  grid_today as (
    select coalesce(sum(case when grid_w > 0 then grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           coalesce(sum(case when grid_w < 0 then -grid_w * (5.0/60) / 1000 else 0 end), 0) as exp,
           count(*) as n
      from (select round(avg(a.grid_w)::numeric) as grid_w
              from public.agg_minute a
             where a.plant_id = v_plant and a.ts >= v_glo and a.ts < v_glo + 86400
             group by (a.ts - v_glo) / 300) b
  ),
  -- Fresh-link sync state (0048): the minute-history bookmark clears when done; the
  -- inverter-history watermark never clears, it parks at today. Progress is days of
  -- the last 60 with any minute or 5-minute row, in the plant's zone — 60 index probes, and only
  -- while something is pending (the pill ignores it otherwise).
  sy as (
    select s.spine, s.inv, s.backfill_next, s.backfill_until, s.temp_next,
           case when s.spine or s.inv then
             (select count(*) from generate_series(0, 59) g(i)
               where exists (select 1 from public.agg_minute a
                              where a.plant_id = v_plant
                                and a.ts >= public.day_start_epoch_tz(s.today - g.i, s.tz)
                                and a.ts <  public.day_start_epoch_tz(s.today - g.i, s.tz) + 86400)
                  -- past 31 days a backfilled day lives in agg_5m (0082)
                  or exists (select 1 from public.agg_5m f
                              where f.plant_id = v_plant
                                and f.ts >= public.day_start_epoch_tz(s.today - g.i, s.tz)
                                and f.ts <  public.day_start_epoch_tz(s.today - g.i, s.tz) + 86400))
           else 60 end as days
      from (select (pc.backfill_next is not null) as spine,
                   (pc.temp_next is not null and pc.temp_next < public.today_tz(plants.tz(v_plant))) as inv,
                   pc.backfill_next, pc.backfill_until, pc.temp_next,
                   public.today_tz(plants.tz(v_plant)) as today,
                   plants.tz(v_plant) as tz
              from plants.settings pc, cfg c where pc.plant_id = v_plant) s
  ),
  plant as (select pu.plant_id as id, pu.plant_name as name from plants.user_plants pu
             where pu.plant_id = v_plant and pu.user_id = auth.uid() limit 1)
  select jsonb_build_object(
    'generatedAt', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    -- the poller's last minute for this plant, as api_health answers it
    'lastTs', (select max(ts) from public.agg_minute where plant_id = v_plant),
    'plant', jsonb_build_object('id', (select id from plant), 'name', coalesce((select name from plant), 'My plant')),
    'totals', jsonb_build_object(
      'pv', t.pv, 'load', t.load, 'grid', t.grid,
      'gridDirection', case when t.grid >= 0 then 'importing' else 'exporting' end,
      'batteryPower', abs(t.batt),
      'batteryDirection', case when abs(t.batt) <= 5 then 'idle' when t.batt > 0 then 'charging' else 'discharging' end,
      'soc', case when t.soc is null then null else round(t.soc) end,
      'todayPv', round(t.today_pv::numeric, 2),
      'todayGridImport', round((case when g.n > 5 then g.imp else t.today_imp end)::numeric, 2),
      'todayGridExport', round((case when g.n > 5 then g.exp else t.today_exp end)::numeric, 2),
      'gridPresent', (select present from gp),
      'phaseDown', coalesce(t.phase_down, false)),
    'config', jsonb_build_object(
      'battCapacity', c.battery_kwh, 'reserve', c.battery_reserve_pct,
      'currency', c.currency, 'timezone', plants.tz(v_plant), 'tariffImport', c.tariff_import, 'tariffExport', c.tariff_export,
      'systemKwp', c.system_kwp, 'panelTilt', c.panel_tilt, 'panelAzimuth', c.panel_azimuth,
      'geometrySource', c.geometry_source,
      'batteryBanks', c.battery_banks, 'hasBattery', c.has_battery, 'hasGrid', c.has_grid, 'featuresSource', c.features_source,
      'battPositiveMeans', c.batt_positive_means, 'battSignSource', c.batt_sign_source,
      'forecastAvailable', v_plant = public.calibration_plant()),
    'inverters', coalesce((select jsonb_agg(snap order by ord, sn) from inv), '[]'::jsonb),
    'sync', (select jsonb_build_object(
      'pending', s.spine or s.inv,
      'spinePending', s.spine,
      'invPending', s.inv,
      'backfillNext', s.backfill_next, 'backfillUntil', s.backfill_until, 'tempNext', s.temp_next,
      'days', s.days, 'window', 60)
      from sy s))
    into v_out
  from totals t, grid_today g, cfg c;
  return v_out;
end $function$;

CREATE OR REPLACE FUNCTION public.api_plant_states()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  -- a variable, not now() in the query, so the planner cuts to the last 2 days
  v_floor bigint := extract(epoch from now())::bigint - 2 * 86400;
  v_out   jsonb := '[]'::jsonb;
  p       record;
  v_ts    bigint;
  v_lo    bigint;
  v_from  bigint;
  v_total int;
  v_on    int;
  v_sync  jsonb;
begin
  for p in select pu.plant_id from plants.user_plants pu
            where pu.user_id = auth.uid() and pu.plant_id in (select public.my_plant_ids())
            order by pu.linked_at, pu.plant_id loop
    select max(ts) into v_ts from public.readings where plant_id = p.plant_id and ts > v_floor;
    if v_ts is null then
      select max(ts) into v_ts from public.readings where plant_id = p.plant_id;
    end if;
    -- known inverters with a row in the last 2 days, or on v_ts's day when that is older
    -- (SOLAR-555); online = in the newest minute and flagged online. One sn_ts probe per
    -- inverter.
    v_lo := public.day_start_epoch_tz((to_timestamp(v_ts) at time zone public.plant_tz(p.plant_id))::date, public.plant_tz(p.plant_id));
    v_from := least(v_floor, v_lo);
    select count(*), count(*) filter (where x.ts = v_ts and x.status::text in ('1', 'online', 'true'))
      into v_total, v_on
      from plants.inverter_info i
      cross join lateral (select rd.ts, rd.status from public.readings rd
                           where rd.sn = i.sn and rd.plant_id = p.plant_id and rd.ts >= v_from and rd.ts <= v_ts
                           order by rd.ts desc limit 1) x
     where i.plant_id = p.plant_id;

    select jsonb_build_object(
             'pending', s.spine or s.inv, 'spinePending', s.spine, 'invPending', s.inv,
             'backfillNext', s.backfill_next, 'backfillUntil', s.backfill_until, 'tempNext', s.temp_next,
             'days', case when s.spine or s.inv then
               (select count(*) from generate_series(0, 59) g(i)
                 where exists (select 1 from public.agg_minute a
                                where a.plant_id = p.plant_id
                                  and a.ts >= public.day_start_epoch_tz(s.today - g.i, s.tz)
                                  and a.ts <  public.day_start_epoch_tz(s.today - g.i, s.tz) + 86400)
                    or exists (select 1 from public.agg_5m f
                                where f.plant_id = p.plant_id
                                  and f.ts >= public.day_start_epoch_tz(s.today - g.i, s.tz)
                                  and f.ts <  public.day_start_epoch_tz(s.today - g.i, s.tz) + 86400))
               else 60 end,
             'window', 60)
      into v_sync
      from (select (pc.backfill_next is not null) as spine,
                   (pc.temp_next is not null and pc.temp_next < public.today_tz(plants.tz(pc.plant_id))) as inv,
                   pc.backfill_next, pc.backfill_until, pc.temp_next,
                   public.today_tz(plants.tz(pc.plant_id)) as today,
                   plants.tz(pc.plant_id) as tz
              from plants.settings pc where pc.plant_id = p.plant_id) s;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', p.plant_id, 'lastTs', v_ts, 'inverters', v_total, 'online', v_on, 'sync', v_sync));
  end loop;
  return v_out;
end $function$;

CREATE OR REPLACE FUNCTION public.api_trends_compare(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  tz as (select public.plant_tz((select id from pl)) as tz),
  t as (select public.today_tz((select tz from tz)) as d),
  b as (
    select d,
           date_trunc('week', d)::date  as week_start,
           date_trunc('month', d)::date as month_start,
           date_trunc('year', d)::date  as year_start
      from t
  ),
  -- same day number last month, null when last month has no such day
  lastm as (
    select g::date as cur,
           case when extract(day from (date_trunc('month', g) - interval '1 month' + (extract(day from g)::int - 1) * interval '1 day'))::int
                     = extract(day from g)::int
                then (date_trunc('month', g) - interval '1 month' + (extract(day from g)::int - 1) * interval '1 day')::date end as prev
      from b, generate_series(b.month_start, b.d, interval '1 day') g
  ),
  -- finished current-slice days with the previous-period day each is paired to
  pairs as (
    select 'week' as k, g::date as cur, (g - interval '7 days')::date as prev
      from b, generate_series(b.week_start, b.d - 1, interval '1 day') g
    union all
    select 'month', cur, prev from lastm, b where cur < b.d
    union all
    -- same date last year; 29 Feb pairs with nothing
    select 'year', g::date,
           case when (g - interval '1 year') + interval '1 year' = g then (g - interval '1 year')::date end
      from b, generate_series(b.year_start, b.d - 1, interval '1 day') g
  ),
  span as (
    select min(least(cur, coalesce(prev, cur))) as lo,
           max(greatest(cur, coalesce(prev, cur))) as hi
      from pairs
  ),
  e as (select * from public._plant_day_energy((select id from pl), (select lo from span), (select hi from span))),
  matched as (
    select p.k, p.cur, p.prev,
           c.pv_kwh as c_pv, c.load_kwh as c_load, c.imp_kwh as c_imp,
           v.pv_kwh as p_pv, v.load_kwh as p_load, v.imp_kwh as p_imp
      from pairs p
      join e c on c.period = p.cur
      join e v on v.period = p.prev
  ),
  -- every period gets a row, even on its first day when no finished day pairs yet
  spans as (
    select ks.k, count(p.cur) as span
      from (values ('week'), ('month'), ('year')) ks(k) left join pairs p on p.k = ks.k
     group by ks.k
  ),
  sums as (
    select s.k,
           jsonb_build_object(
             'cur',  jsonb_build_object('pv', coalesce(round(sum(m.c_pv)::numeric, 1), 0), 'load', coalesce(round(sum(m.c_load)::numeric, 1), 0), 'imp', coalesce(round(sum(m.c_imp)::numeric, 1), 0)),
             'prev', jsonb_build_object('pv', coalesce(round(sum(m.p_pv)::numeric, 1), 0), 'load', coalesce(round(sum(m.p_load)::numeric, 1), 0), 'imp', coalesce(round(sum(m.p_imp)::numeric, 1), 0)),
             'days', count(m.cur),
             'span', s.span) as v
      from spans s left join matched m on m.k = s.k
     group by s.k, s.span
  ),
  -- ---- today so far, and the day it pairs with up to the same time ----
  tlo as (select public.day_start_epoch_tz(b.d, (select tz from tz)) as lo from b),
  -- today's latest poll, the one the tiles show; it must be today's
  latest as (
    select r.ts from public.readings r, tlo
     where r.plant_id = (select id from pl) and r.ts >= tlo.lo
     order by r.ts desc limit 1
  ),
  -- today's latest poll as a local clock time; each matching day is read at that clock time
  el as (select (to_timestamp(latest.ts) at time zone (select tz from tz))::time as t from latest),
  tpairs as (
    select 'today' as k, (b.d - 1) as prev from b
    union all select 'week', (b.d - 7) from b
    union all select 'month', (select prev from lastm, b where lastm.cur = b.d)
    union all select 'year', case when (b.d - interval '1 year') + interval '1 year' = b.d then (b.d - interval '1 year')::date end from b
  ),
  tc as (
    select p.k, p.prev, x.lo, extract(epoch from ((p.prev + el.t) at time zone (select tz from tz)))::bigint as cut
      from tpairs p, el,
           lateral (select public.day_start_epoch_tz(p.prev, (select tz from tz)) as lo) x
     where p.prev is not null
  ),
  -- each known inverter with a row in the last 2 days (SOLAR-555; was: those in today's
  -- latest poll, which drops one the poller left out): its last good reading on the matching day at or
  -- before the moment, from readings, else the 5-minute history (counters as at the
  -- bucket's end). One index probe per inverter per pair.
  inv as (
    select i.sn from plants.inverter_info i
     where i.plant_id = (select id from pl)
       and exists (select 1 from public.readings r
                    where r.sn = i.sn and r.plant_id = i.plant_id
                      and r.ts > extract(epoch from now())::bigint - 2 * 86400 and r.ts <= (select ts from latest))
  ),
  per as (
    select tc.k, i.sn,
           coalesce(x.pv, y.pv) as pv, coalesce(x.load, y.load) as load, coalesce(x.imp, y.imp) as imp,
           (x.ts is not null or y.ts is not null) as found
      from tc cross join inv i
      left join lateral (
        -- an upload dated before the matching day holds that day's eve: 0 so far (SOLAR-648)
        select r.ts,
               case when r.device_time ~ '^\d{4}-\d{2}-\d{2} ' and left(r.device_time, 10) < tc.prev::text then 0 else r.pv_today_kwh end as pv,
               case when r.device_time ~ '^\d{4}-\d{2}-\d{2} ' and left(r.device_time, 10) < tc.prev::text then 0 else r.load_today_kwh end as load,
               case when r.device_time ~ '^\d{4}-\d{2}-\d{2} ' and left(r.device_time, 10) < tc.prev::text then 0 else r.grid_import_today_kwh end as imp
          from public.readings r
         where r.sn = i.sn and r.plant_id = (select id from pl)
           and r.ts >= tc.lo and r.ts <= tc.cut and r.device_time is not null
         order by r.ts desc limit 1) x on true
      left join lateral (
        select f.ts, f.pv_today_kwh as pv, f.load_today_kwh as load, f.grid_import_today_kwh as imp
          from public.readings_5m f
         where x.ts is null
           and f.plant_id = (select id from pl) and f.sn = i.sn
           and f.ts >= tc.lo and f.ts <= tc.cut - 300 and f.pv_today_kwh is not null
         order by f.ts desc limit 1) y on true
  ),
  ctr as (
    select k, sum(pv) as pv, sum(load) as load, sum(imp) as imp
      from per group by k
    having bool_and(found)
  ),
  -- the matching day from the minute history, 5-minute power summed to kWh: the grid
  -- figure always, solar and home when no inverter counters cover that day (SOLAR-508)
  ig as (
    select tc.k,
           coalesce(sum(case when a.grid_w > 0 then a.grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           coalesce(sum(greatest(a.pv_w, 0) * (5.0/60) / 1000), 0) as pv,
           coalesce(sum(greatest(a.load_w, 0) * (5.0/60) / 1000), 0) as load,
           count(a.hm) as n
      from tc left join lateral (
        select q.hm, q.grid_w, q.pv_w, q.load_w from public.q_day_agg((select id from pl), tc.prev, null) q
         where q.hm <= to_char(public.local_ts_tz(tc.cut, (select tz from tz)), 'HH24:MI')) a on true
     group by tc.k
  ),
  -- counters first; a plant just imported has none for yesterday, only the minute history
  nowv as (
    select g.k, jsonb_build_object(
             'pv',   coalesce(round(coalesce(c.pv, g.pv)::numeric, 1), 0),
             'load', coalesce(round(coalesce(c.load, g.load)::numeric, 1), 0),
             'imp',  coalesce(round((case when g.n > 5 then g.imp else c.imp end)::numeric, 1), 0)) as v
      from ig g left join ctr c on c.k = g.k
     where c.k is not null or g.n > 5
  )
  select coalesce((select jsonb_object_agg(s.k, s.v || jsonb_build_object('now', (select v from nowv where nowv.k = s.k))) from sums s), '{}'::jsonb)
         || jsonb_build_object('today', jsonb_build_object(
              'cur',  jsonb_build_object('pv', 0, 'load', 0, 'imp', 0),
              'prev', coalesce((select v from nowv where k = 'today'), jsonb_build_object('pv', 0, 'load', 0, 'imp', 0)),
              'days', case when exists (select 1 from nowv where k = 'today') then 1 else 0 end,
              'span', 1))
$function$;

CREATE OR REPLACE FUNCTION public.billing_jobs(p_cmd text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  return case p_cmd
    when 'history_take' then billing.history_take()
    when 'history_step' then billing.history_step((p_args->>'id')::bigint, (p_args->>'day')::date,
                               coalesce((p_args->>'failed')::boolean, false), coalesce((p_args->>'throttled')::boolean, false),
                               now(), (p_args->>'claim')::uuid)
    when 'history_renew' then to_jsonb(coalesce(billing.history_renew((p_args->>'id')::bigint, (p_args->>'claim')::uuid), false))
    when 'fetching'     then coalesce((select jsonb_agg(distinct plant) from billing.history_fetches
                                        where status in ('queued', 'running')), '[]'::jsonb)
    when 'login_seen'   then plants.list_seen((p_args->>'login')::uuid, p_args->'plants')
    when 'alerts'       then billing.alerts()
    when 'heartbeat'    then (select '{}'::jsonb from (select billing.heartbeat(p_args->>'job', now(), p_args->'result',
                               p_args->>'error')) x)
    when 'winback'      then billing.winback_return(p_args->>'reference')
    when 'outbox_sweep' then billing.outbox_sweep()
    when 'outbox_take'  then billing.outbox_take(coalesce((p_args->>'limit')::int, 50))
    when 'outbox_done'  then (select '{}'::jsonb from (select billing.outbox_done((p_args->>'id')::bigint,
                               (p_args->>'ok')::boolean, p_args->>'error', (p_args->>'retry_s')::int,
                               now(), coalesce((p_args->>'refund')::boolean, false))) x)
    else billing.unknown_command(p_cmd)
  end;
end $function$;

CREATE OR REPLACE FUNCTION public.billing_links(p_cmd text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'private', 'pg_temp'
AS $function$
declare acc uuid;
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  acc := billing.account_of((p_args->>'user')::uuid);
  return case p_cmd
    when 'state' then billing.account_state(acc) || jsonb_build_object('live', true,
                        'login_known', exists (select 1 from plants.login_info l where l.account = acc
                                                  and lower(l.username) = lower(p_args->>'username')))
    when 'claim_plant' then (select billing.account_state(acc) from (select plants.claim(acc,
                               coalesce(p_args->>'brand', plants.default_brand()), p_args->>'plant', p_args->>'name')) x)
    else billing.unknown_command(p_cmd)
  end;
end
$function$;

CREATE OR REPLACE FUNCTION public.billing_v2(p_cmd text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  acc uuid;
  uid uuid;
  plant_list bigint[];
  mk text;
  out jsonb;
begin
  if p_args ? 'user' then
    select id into acc from billing.accounts where user_id = (p_args->>'user')::uuid;
    if acc is null and p_cmd <> 'delete_account' then
      mk := coalesce(p_args->>'market', (select min(code) from billing.markets having count(*) = 1));
      if mk is null then raise exception 'which market?' using errcode = '22023'; end if;
      insert into billing.accounts (user_id, market) values ((p_args->>'user')::uuid, mk)
      on conflict (user_id) do nothing;
      select id into acc from billing.accounts where user_id = (p_args->>'user')::uuid;
    end if;
  end if;
  if jsonb_typeof(p_args->'plants') = 'array' then
    plant_list := array(select jsonb_array_elements_text(p_args->'plants')::bigint);
  end if;
  if p_cmd = 'apply_payment' then
    -- for the billing function's counts: the user id, and for a first plan whether it is a return
    out := billing.apply_payment(p_args->>'reference', p_args->'tx');
    select a.user_id, a.id into uid, acc from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
      join billing.accounts a on a.id = i.account where pa.reference = p_args->>'reference';
    if out->>'action' = 'applied' and out->>'kind' = 'purchase' then
      out := out || jsonb_build_object('days_since_plan',
        (select extract(day from now() - max(ended_at))::int from billing.subscriptions where account = acc and status = 'ended'));
    end if;
    return out || jsonb_build_object('user', uid);
  end if;
  return case p_cmd
    when 'account_state'    then billing.account_state(acc)
    when 'start_checkout'   then billing.start_checkout(acc, p_args->>'plan', p_args->>'interval', (p_args->>'extras')::int, plant_list)
    when 'upgrade'          then billing.upgrade(acc, p_args->>'plan', (p_args->>'extras')::int, plant_list, p_interval => p_args->>'interval')
    when 'downgrade'        then billing.downgrade(acc, p_args->>'plan', (p_args->>'extras')::int,
                                   array(select jsonb_array_elements_text(coalesce(p_args->'drop', '[]'))::bigint),
                                   p_interval => p_args->>'interval')
    when 'switch_interval'  then billing.switch_interval(acc, p_args->>'interval')
    when 'cancel'           then billing.cancel(acc)
    when 'undo_cancel'      then billing.undo_cancel(acc)
    when 'pay_now'          then billing.pay_now(acc)
    when 'start_card_check' then billing.start_card_check(acc)
    when 'delete_account'   then case when acc is null then jsonb_build_object('deleted', false) else billing.delete_account(acc) end
    when 'begin_attempt'    then billing.begin_attempt((p_args->>'invoice')::uuid, p_args->>'channel', now(), acc)
    when 'renewal_pages'    then billing.renewal_pages(acc)
    when 'verify_unanswered' then billing.verify_unanswered(p_args->>'reference')
    when 'attempt_page'     then coalesce(billing.attempt_page(p_args->>'reference', p_args->>'url'), '{}'::jsonb)
    when 'record_refund'    then billing.record_refund((p_args->>'refund')::uuid, p_args->>'error', p_args->>'provider_id')
    when 'record_refund_event' then billing.record_refund_event(p_args->>'reference', p_args->>'status', p_args->>'provider_id',
                                   (p_args->>'amount')::int, p_args->>'reason', now(), p_args->>'provider_ref')
    when 'record_dispute'   then billing.record_dispute(p_args->>'reference', p_args->>'event', p_args->>'status',
                                   (p_args->>'lost')::boolean, (p_args->>'amount')::int, now(), p_args->>'dispute_id')
    when 'event_begin'      then billing.event_begin(p_args->>'provider', p_args->>'type', p_args->>'entity', p_args->>'status', p_args->'payload')
    when 'event_done'       then (select '{}'::jsonb from (select billing.event_done((p_args->>'id')::bigint, p_args->>'error')) x)
    when 'run'              then billing.run()
    -- who opened the try, and the bill it pays (the paid message and its count)
    when 'attempt_user'     then (select jsonb_build_object('user', a.user_id, 'kind', i.kind, 'plan', i.plan,
                                   'plan_name', i.plan_name, 'interval', i.interval,
                                   'changed', i.kind = 'renewal' and i.plan is distinct from
                                     (select x.plan from billing.invoices x where x.subscription = i.subscription
                                         and x.status = 'paid' and x.kind in ('purchase', 'renewal', 'upgrade')
                                         and x.id <> i.id and x.period_start < i.period_start
                                       order by x.period_start desc, x.paid_at desc limit 1))
                                   from billing.payment_attempts pa
                                   join billing.invoices i on i.id = pa.invoice join billing.accounts a on a.id = i.account
                                  where pa.reference = p_args->>'reference')
  end;
end $function$;

CREATE OR REPLACE FUNCTION public.email_plant_inverters(p_plant bigint)
 RETURNS TABLE(sn text, last_dev bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select i.sn, s.last_dev
    from plants.inverter_info i
    left join private.inverter_alert_state s on s.plant_id = i.plant_id and s.sn = i.sn
   where i.plant_id = p_plant
   order by i.sn
$function$;

CREATE OR REPLACE FUNCTION public.grid_live(p_volts double precision)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ select p_volts > 100 $function$;

CREATE OR REPLACE FUNCTION public.independence_pct(p_home double precision, p_import double precision)
 RETURNS double precision
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case when coalesce(p_home, 0) > 0
              then greatest(0, least(100, ((p_home - coalesce(p_import, 0)) / p_home) * 100)) else 0 end
$function$;

CREATE OR REPLACE FUNCTION public.inverters_cached_many(p_accounts uuid[], p_plants bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(account_id uuid, sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text, gsn text, comm_type text, plant_name text, ord integer, status integer, last_reading jsonb, carried_run integer, upload_s integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
#variable_conflict use_column
declare
  -- a variable, not now() in the query, so the planner opens 2 partitions, not all
  v_floor bigint := extract(epoch from now())::bigint - 86400;
begin
  return query
  select a.id, i.sn, i.plant_id, m.alias, m.model, m.soft_ver, m.hmi_ver,
         m.gsn, m.comm_type, m.plant_name, m.ord, m.status,
         lr.row as last_reading,
         coalesce(cr.n, 0)::integer as carried_run,
         ug.s as upload_s
    from unnest(p_accounts) a(id)
    join private.inverters i
      on (i.account_id = a.id
          or i.plant_id in (select lp.plant from plants.login_plants lp where lp.login = a.id))
     and (p_plants is null or i.plant_id = any (p_plants))
    left join private.meta m on m.sn = i.sn
    left join lateral (
      select to_jsonb(r) as row
        from public.readings r
       where r.sn = i.sn and r.ts > v_floor
       order by r.ts desc
       limit 1) lr on true
    left join lateral (
      select count(*) as n
        from public.readings r
       where r.sn = i.sn and r.ts > v_floor
         and r.ts > coalesce((select max(r2.ts) from public.readings r2
                               where r2.sn = i.sn and r2.ts > v_floor and not r2.carried), 0)) cr on true
    left join lateral (
      select min(g.gap)::integer as s
        from (select extract(epoch from (d.dt - lead(d.dt) over (order by d.dt desc))) as gap
                from (select distinct t.device_time::timestamp as dt
                        from (select r.device_time
                                from public.readings r
                               where r.sn = i.sn and r.ts > v_floor
                               order by r.ts desc
                               limit 20) t
                       where t.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
                       order by 1 desc
                       limit 3) d) g
       where g.gap is not null
      having count(*) = 2) ug on true
   order by a.id, coalesce(m.ord, 9999), i.sn;
end $function$;

CREATE OR REPLACE FUNCTION public.link_login_allowed(p_user uuid, p_username text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select plants.link_allowed(p_user, plants.brand_for_username(p_username), p_username)
$function$;

CREATE OR REPLACE FUNCTION public.link_login_live(p_user uuid, p_username text, p_access text, p_expires bigint, p_refresh text, p_plants jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  acc uuid;
  login uuid;
  mine uuid[];
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  -- the login's lock, then the account, then the plants (R19); every copy of the username too
  mine := private.username_logins(p_user, p_username);
  perform private.login_lock(mine, 'ok', p_user,
    array(select lp.plant from plants.login_plants lp where lp.login = any (mine)
          union select (x->>'id')::bigint from jsonb_array_elements(plants.list_ids(plants.brand_for_username(p_username), p_plants)) x));
  if not plants.link_allowed(p_user, plants.brand_for_username(p_username), p_username) then
    raise exception 'one login' using errcode = '22023';
  end if;
  acc := billing.account_of(p_user);
  login := plants.link_login(acc, plants.brand_for_username(p_username), p_username, coalesce(p_plants, '[]'::jsonb), now(), 'owner',
                             null, p_access, p_expires);
  -- a fresh sign-in replaces whatever the other copies of this username held
  update plants.logins
     set access_token = p_access, access_expires_at = p_expires, status = 'ok', last_error = null
   where id in (select private.login_copies(login));
  perform public.account_refresh_set(login, p_refresh);
  return login;
end
$function$;

CREATE OR REPLACE FUNCTION public.login_outcomes(p_outcomes jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update plants.logins a set last_try_at = now(), last_try = o.outcome
    from jsonb_to_recordset(coalesce(p_outcomes, '[]'::jsonb)) as o(account uuid, outcome text)
   where a.id = o.account and o.outcome in ('ok', 'vendor', 'ours')
$function$;

CREATE OR REPLACE FUNCTION public.msg_email_take(p_limit integer DEFAULT 50, p_lane text DEFAULT 'urgent'::text)
 RETURNS TABLE(id bigint, claim uuid, tries integer, batch_key text, event_id bigint, user_id uuid, to_email text, plant_id bigint, plant_name text, tz text, kind text, key text, data jsonb, unsub_token uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_claim uuid := gen_random_uuid();
  r msg.outbox;
  v_why text;
  v_leased int := 0;
  v_moved int;
  k text;
begin
  -- rows already bound to a batch key: their call may have gone. Each passes the guard; what
  -- is left of a group is leased together and goes again under its key (notify).
  for k in
    select o.batch_key from msg.outbox o
     where o.channel = 'email' and o.lane = p_lane and o.status = 'queued' and o.batch_key is not null
       and o.not_before <= now() and (o.claimed_until is null or o.claimed_until < now())
     group by o.batch_key order by min(o.not_before), o.batch_key
  loop
    exit when v_leased >= p_limit;
    -- a worker taking the same group at once waits here, then finds it leased
    for r in
      select o.* from msg.outbox o
       where o.batch_key = k and o.status = 'queued' and o.not_before <= now()
         and (o.claimed_until is null or o.claimed_until < now())
       order by o.id
       for update
    loop
      v_why := msg.email_guard(r);
      if v_why = 'wait' then continue; end if;
      if v_why is not null then
        update msg.outbox o set status = 'dropped', drop_reason = v_why, claim = null, claimed_until = null, done_at = now()
         where o.id = r.id;
        continue;
      end if;
      update msg.outbox o set claim = v_claim, claimed_until = now() + interval '2 minutes', tries = o.tries + 1
       where o.id = r.id;
      v_leased := v_leased + 1;
    end loop;
  end loop;

  -- dropped rows don't count: take again until p_limit are leased or nothing moves (review)
  loop
    v_moved := 0;
    for r in
      select o.* from msg.outbox o
       where o.channel = 'email' and o.lane = p_lane and o.status = 'queued' and o.not_before <= now()
         and (o.claimed_until is null or o.claimed_until < now())  -- a lease that ran out: the reply was lost
         and o.batch_key is null
         and msg.email_guard(o) is distinct from 'wait'            -- waiting rows never fill the take
       order by o.not_before, o.id
       limit greatest(p_limit - v_leased, 0)
       for update skip locked
    loop
      v_why := msg.email_guard(r);
      if v_why = 'wait' then continue; end if;                     -- its "down" moved on since the select
      v_moved := v_moved + 1;
      if v_why is not null then
        update msg.outbox o set status = 'dropped', drop_reason = v_why, claim = null, claimed_until = null, done_at = now()
         where o.id = r.id;
        continue;
      end if;
      update msg.outbox o set claim = v_claim, claimed_until = now() + interval '2 minutes', tries = o.tries + 1
       where o.id = r.id;
      v_leased := v_leased + 1;
    end loop;
    exit when v_moved = 0 or v_leased >= p_limit;
  end loop;

  -- the old email_claim's fields, so notify builds the same email
  return query
  select o.id, v_claim, o.tries, o.batch_key, q.id, q.user_id,
         coalesce(q.to_email, u.email::text, o.to_email), q.plant_id,
         coalesce(pu.plant_name, (select pu2.plant_name from plants.user_plants pu2
                                   where pu2.user_id = q.user_id order by pu2.linked_at limit 1)),
         case when q.plant_id is not null then public.plant_tz(q.plant_id) else 'Africa/Johannesburg' end,
         q.kind, q.key,
         -- email_claim's per-kind data (0247): need a hand with a login names choosing plants;
         -- a report has no free-week wording since billing went live
         case when q.kind = 'need_a_hand' and exists (select 1 from plants.login_info a where a.user_id = q.user_id)
                then coalesce(q.data, '{}'::jsonb) || '{"choose": true}'::jsonb
              when q.kind like 'report\_%' then q.data - 'freeWeekEnds'
              else q.data end,
         -- a kind with a switch gets the user's unsubscribe token, as email_claim
         case when q.user_id is not null and private.email_switch_of(q.kind, q.data) is not null
              then public.email_unsub_token(q.user_id) end
    from msg.outbox o
    join public.email_queue q on q.id = o.event_id
    left join auth.users u on u.id = q.user_id
    left join plants.user_plants pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
   where o.claim = v_claim and o.status = 'queued'
   order by o.batch_key nulls last, o.id;
end $function$;

CREATE OR REPLACE FUNCTION public.msg_push_take(p_limit integer DEFAULT 200)
 RETURNS TABLE(id bigint, claim uuid, event_id bigint, kind text, plant_id bigint, data jsonb, created numeric, tz text, plant_name text, plants integer, endpoint text, p256dh text, auth text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_claim uuid := gen_random_uuid();
  r msg.outbox;
  v_why text;
  v_n int;
begin
  -- 1. a lease that ran out: the reply was lost or the worker died. It goes again.
  update msg.push_sends s set status = 'queued', claim = null, claimed_until = null, updated_at = now()
   where s.status = 'sending' and s.claimed_until < now();

  -- 2. sends whose device was removed, then sends past their event's expiry
  update msg.push_sends s set status = 'gone', last_error = 'device removed', updated_at = now()
   where s.status = 'queued' and s.sub_id is null;
  update msg.push_sends s set status = 'failed', last_error = 'too old', updated_at = now()
    from msg.outbox o
   where o.id = s.outbox_id and s.status = 'queued' and o.expires_at <= now();

  -- 3. settle rows with nothing left open
  perform msg.push_settle(array(
    select o.id from msg.outbox o
     where o.channel = 'push' and o.status = 'queued' and o.claimed_until is not null
       and not exists (select 1 from msg.push_sends s where s.outbox_id = o.id and s.status in ('queued', 'sending'))));

  -- 4. new rows: guard, then one send per device
  for r in
    select o.* from msg.outbox o
     where o.channel = 'push' and o.status = 'queued' and o.claimed_until is null and o.not_before <= now()
       and msg.push_guard(o) is distinct from 'wait'           -- waiting rows never fill the take
     order by o.lane = 'urgent' desc, o.not_before, o.id
     limit p_limit
     for update skip locked
  loop
    v_why := msg.push_guard(r);
    if v_why = 'wait' then continue; end if;                  -- its "down" moved on since the select
    if v_why is not null then
      update msg.outbox o set status = 'dropped', drop_reason = v_why, done_at = now() where o.id = r.id;
      continue;
    end if;
    insert into msg.push_sends (outbox_id, sub_id)
    select r.id, ps.id
      from public.push_subs ps
      join public.email_queue q on q.id = r.event_id
     where ps.user_id = r.user_id and ps.platform = 'web'
       -- a "back" goes only to the devices that took its "down" through the outbox
       and (q.pair_key is null
            or not exists (select 1 from public.email_queue d
                            where d.user_id = q.user_id and d.key = q.pair_key and d.push_skip = 'outbox')
            or ps.id in (select s.sub_id from public.email_queue d
                           join msg.outbox od on od.dedupe_key = d.id || ':push'
                           join msg.push_sends s on s.outbox_id = od.id and s.status = 'sent'
                          where d.user_id = q.user_id and d.key = q.pair_key));
    get diagnostics v_n = row_count;
    if v_n = 0 then
      update msg.outbox o set status = 'dropped', drop_reason = 'no device', done_at = now() where o.id = r.id;
    else
      update msg.outbox o set claimed_until = o.expires_at, tries = o.tries + 1 where o.id = r.id;
    end if;
  end loop;

  -- 5. lease due sends under one claim
  return query
  with leased as (
    update msg.push_sends s
       set status = 'sending', claim = v_claim, claimed_until = now() + interval '2 minutes',
           tries = s.tries + 1, updated_at = now()
     where s.id in (select s2.id from msg.push_sends s2
                      join msg.outbox o2 on o2.id = s2.outbox_id
                     where s2.status = 'queued' and s2.not_before <= now() and o2.expires_at > now()
                       and s2.sub_id is not null
                     order by o2.lane = 'urgent' desc, s2.not_before, s2.id
                     limit p_limit
                     for update of s2 skip locked)
    returning s.id, s.outbox_id, s.sub_id)
  select l.id, v_claim, q.id, q.kind, q.plant_id,
         q.data, extract(epoch from q.created_at), public.plant_tz(q.plant_id), pu.plant_name,     -- 0264
         (select count(*)::int from plants.user_plants n where n.user_id = q.user_id),
         ps.endpoint, ps.p256dh, ps.auth
    from leased l
    join msg.outbox o on o.id = l.outbox_id
    join public.email_queue q on q.id = o.event_id
    join public.push_subs ps on ps.id = l.sub_id
    left join plants.user_plants pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
   order by l.id;
end $function$;

CREATE OR REPLACE FUNCTION public.my_plant_ids()
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select se.plant from billing.seats se join billing.accounts a on a.id = se.account
    join plants.plant_info p on p.id = se.plant
   where a.user_id = auth.uid() and se.closed_at is null and (select f.history_purged_at from billing.plant_facts f where f.plant = p.id) is null
     and not private.history_deleting(se.plant)                                -- 0277
     -- a share removed or a plant gone from the login: hidden; its history stays and shows again
     and billing.has_route(a.id, se.plant, false)
     -- not paying (ended, or over its places): its own history only, never a plant another
     -- account keeps, whose seat here never closes (it would see that payer's readings for good)
     and ((select st.state in ('trialing', 'active', 'past_due') and not st.must_choose
             from billing.account_status(a.id, now()) st)
          or not billing.kept_elsewhere(a.id, se.plant, now()))
$function$;

CREATE OR REPLACE FUNCTION public.plant_bookmarks_clear(p_plants bigint[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update public.plant_config set backfill_next = null, backfill_until = null, temp_next = null
   where plant_id = any (coalesce(p_plants, '{}'))
$function$;

CREATE OR REPLACE FUNCTION public.plant_bootstrap_kick(p_plant bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  fn_base text;
  fn text;
  auth jsonb;
  acc uuid;
  rid bigint;                                                             -- 0235
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net not enabled here - not kicking bootstrap for plant %', p_plant;
    return;
  end if;
  fn_base := private.functions_url();                                     -- 0280
  auth := jsonb_build_object(
    'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
    'Content-Type', 'application/json');
  foreach fn in array array['sync-plant-energy', 'recover'] loop
    rid := net.http_post(                                                 -- 0235: keep the id
      url := fn_base || '/' || fn || '?plant=' || p_plant,
      headers := auth,
      body := '{}'::jsonb,
      timeout_milliseconds := 150000);
    if fn = 'recover' then                                                -- 0235
      insert into private.recover_kicks (plant_id, request_id)
        select p_plant, rid where exists (select 1 from public.plant_config where plant_id = p_plant)
        on conflict (plant_id) do update set request_id = excluded.request_id, at = now();
    end if;
  end loop;
  select account_id into acc from plants.user_plants where plant_id = p_plant limit 1;
  if acc is not null then
    perform net.http_post(
      url := fn_base || '/poll',
      headers := auth,
      body := jsonb_build_object('account', acc),
      timeout_milliseconds := 55000);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION public.plant_cfg(p_plant bigint)
 RETURNS TABLE(timezone text, currency text, lat double precision, lon double precision, system_kwp double precision, tariff_import double precision, battery_kwh double precision, battery_reserve_pct double precision, panel_tilt double precision, panel_azimuth double precision, geometry_source text, tariff_export double precision, battery_banks text, has_battery boolean, has_grid boolean, features_source text, batt_positive_means text, batt_sign_source text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select plants.tz(p_plant),
         coalesce(c.currency, 'ZAR'),
         coalesce(c.lat, public.cfg('LAT')), coalesce(c.lon, public.cfg('LON')),
         c.system_kwp,   -- the owner's figure or nothing; the Solar tab then asks for it
         coalesce(c.tariff_import, 0),
         -- app_config's pack size describes the deployment's own plant only; any
         -- other plant reads null until its owner sets it (the UI then asks).
         coalesce(c.battery_kwh, case when x.id = public.calibration_plant() then public.cfg('BATTERY_KWH') end),
         coalesce(c.battery_reserve_pct, public.cfg('BATTERY_RESERVE_PCT'), 20),
         coalesce(c.panel_tilt, public.cfg('PANEL_TILT'), 15),
         coalesce(c.panel_azimuth, public.cfg('PANEL_AZIMUTH'), 0),
         coalesce(c.geometry_source, 'default'),
         coalesce(c.tariff_export, 0),
         coalesce(c.battery_banks, 'per-inverter'),
         c.has_battery, c.has_grid,
         coalesce(c.features_source, 'default'),
         c.batt_positive_means, coalesce(c.batt_sign_source, 'default')
    from (select p_plant as id) x
    left join public.plant_config c on c.plant_id = x.id
$function$;

CREATE OR REPLACE FUNCTION public.plant_config_seed(p_rows jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- the brand's zone for the plant, when it gives a real one (R26); else the plant keeps its market's
  with z as (update plants.plants p set time_zone = r->>'timezone'
               from jsonb_array_elements(p_rows) r
              where p.id = (r->>'plant_id')::bigint and plants.tz_valid(nullif(r->>'timezone', ''))
                and p.time_zone is distinct from r->>'timezone' returning p.id)
  insert into public.plant_config (plant_id, currency, lat, lon, panel_azimuth, geometry_source,
                                   backfill_next, backfill_until, temp_next)
  select (r->>'plant_id')::bigint,
         coalesce(nullif(upper(r->>'currency'), ''), 'ZAR'),
         nullif(r->>'lat', '')::double precision,
         nullif(r->>'lon', '')::double precision,
         case when nullif(r->>'lat', '')::double precision > 0 then 180 else 0 end,
         'default',
         case when not paused then (now() at time zone tz)::date - 60 end,
         case when not paused then (now() at time zone tz)::date - 14 end,
         case when not paused then (now() at time zone tz)::date - 60 end
    from jsonb_array_elements(p_rows) r,
         lateral (select case when plants.tz_valid(nullif(r->>'timezone', '')) then r->>'timezone'
                              else plants.tz((r->>'plant_id')::bigint) end as tz,
                         coalesce((r->>'paused')::boolean, false) as paused) z
  on conflict (plant_id) do nothing
$function$;

CREATE OR REPLACE FUNCTION public.plant_features_detect(p_plant bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  cur record;
  hb boolean;
  hg boolean;
  n  bigint;
  v_floor bigint := extract(epoch from now())::bigint - 86400;
begin
  select has_battery, has_grid, features_source, features_checked_at into cur from public.plant_config where plant_id = p_plant;
  if cur.features_source = 'user' then
    return jsonb_build_object('plant', p_plant, 'skipped', 'user override');
  end if;
  -- battery and grid rarely change: once decided, a day between checks
  if cur.features_source = 'detected' and cur.features_checked_at > now() - interval '1 day' then
    return jsonb_build_object('plant', p_plant, 'skipped', 'checked today');
  end if;
  select count(*),
         bool_or((batt_soc between 1 and 100) or coalesce(batt_voltage_v, 0) > 10),
         bool_or(coalesce(public.grid_live(grid_volt_v), false) or coalesce(grid_import_today_kwh, 0) > 0
                 or coalesce(grid_export_today_kwh, 0) > 0 or abs(coalesce(grid_w, 0)) > 50)
    into n, hb, hg
    from public.readings
   where plant_id = p_plant and ts > v_floor and not carried;
  if n < 30 then
    return jsonb_build_object('plant', p_plant, 'decided', false, 'rows', n);
  end if;
  update public.plant_config
     set has_battery = hb, has_grid = hg, features_source = 'detected', features_updated_at = now()
   where plant_id = p_plant
     and (has_battery is distinct from hb or has_grid is distinct from hg or features_source = 'default');
  update public.plant_config set features_checked_at = now() where plant_id = p_plant;
  return jsonb_build_object('plant', p_plant, 'decided', true, 'hasBattery', hb, 'hasGrid', hg, 'rows', n);
end $function$;

CREATE OR REPLACE FUNCTION public.plant_history_loading(p_plant bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from public.plant_config c where c.plant_id = p_plant and c.backfill_next is not null)
$function$;

CREATE OR REPLACE FUNCTION public.plant_link(p_user uuid, p_plant bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('linked_at', u.linked_at, 'plant_name', u.plant_name)
    from plants.user_plants u
   where u.plant_id = p_plant and (p_user is null or u.user_id = p_user)
   order by u.share_gone_at is not null, u.linked_at limit 1
$function$;

CREATE OR REPLACE FUNCTION public.plant_tz(p_plant bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$ select plants.tz(p_plant) $function$;

CREATE OR REPLACE FUNCTION public.plant_vendor(p_plant bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p.vendor_id from plants.plants p where p.id = p_plant
$function$;

CREATE OR REPLACE FUNCTION public.plants_configured(p_plants bigint[])
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select c.plant_id from public.plant_config c where c.plant_id = any (coalesce(p_plants, '{}'))
$function$;

CREATE OR REPLACE FUNCTION public.plants_list_seen(p_login uuid, p_plants jsonb, p_mode text DEFAULT 'sync'::text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select plants.list_seen(p_login, p_plants, now(), p_mode)
$function$;

CREATE OR REPLACE FUNCTION public.plants_of_login(p_login uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'vendor_id', p.vendor_id) order by p.id), '[]'::jsonb)
    from plants.login_plants lp join plants.plants p on p.id = lp.plant where lp.login = p_login
$function$;

CREATE OR REPLACE FUNCTION public.plants_seen_before(p_user uuid, p_plants bigint[])
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select count(*)::int
    from plants.plant_info p
   where p.id = any (coalesce(p_plants, '{}'))
     and (select f.trial_used_at from billing.plant_facts f where f.plant = p.id) < (select u.created_at from auth.users u where u.id = p_user)
     and not exists (select 1 from billing.seats se join billing.accounts a on a.id = se.account
                      where se.plant = p.id and se.closed_at is null and a.user_id <> p_user)
$function$;

CREATE OR REPLACE FUNCTION public.poll_commit(p_account uuid, p_ts bigint, p_readings jsonb, p_strings jsonb, p_agg jsonb, p_meta jsonb, p_inverters jsonb, p_access text, p_expires bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
declare
  n_readings int := 0;
  n_strings  int := 0;
  gaps       bigint[] := '{}';
  plant_list     bigint[] := '{}';
  a          record;
  prev_ts    bigint;
begin
  if to_regclass('pg_temp._rd') is not null then drop table _rd; end if;
  if to_regclass('pg_temp._st') is not null then drop table _st; end if;

  create temp table _rd on commit drop as
    select * from jsonb_populate_recordset(null::public.readings, coalesce(p_readings, '[]'::jsonb))
     where plant_id is not null;
  delete from public.readings r using _rd where r.ts = p_ts and r.ts = _rd.ts and r.sn = _rd.sn;
  insert into public.readings select * from _rd on conflict do nothing;
  select count(*) into n_readings from _rd;

  create temp table _st on commit drop as
    select * from jsonb_populate_recordset(null::public.strings, coalesce(p_strings, '[]'::jsonb))
     where plant_id is not null;
  -- Remember every input that has ever produced, and how many inputs each inverter
  -- reports (0061). An input that has never produced is not wired to anything: its
  -- all-zero row is dropped rather than stored every minute. An input that has
  -- produced keeps every row, zeros included, so a string that dies still shows.
  update private.meta m
     set used_strings = (select array_agg(distinct x order by x)
                           from unnest(m.used_strings || array(
                             select t.no from _st t
                              where t.sn = m.sn and private.string_live(t.volt_v, t.current_a, t.power_w, t.today_kwh))) x)
   where exists (select 1 from _st t
                  where t.sn = m.sn and not (t.no = any(m.used_strings))
                    and private.string_live(t.volt_v, t.current_a, t.power_w, t.today_kwh));
  update private.meta m set string_slots = c.n
    from (select sn, count(*)::int as n from _st group by sn) c
   where m.sn = c.sn and m.string_slots is distinct from c.n;
  delete from _st t
   where not private.string_live(t.volt_v, t.current_a, t.power_w, t.today_kwh)
     and not exists (select 1 from plants.meta_info m where m.sn = t.sn and t.no = any(m.used_strings));
  delete from public.strings s using _st where s.ts = p_ts and s.ts = _st.ts and s.sn = _st.sn and s.no = _st.no;
  insert into public.strings select * from _st on conflict do nothing;
  select count(*) into n_strings from _st;

  for a in
    select (r->>'plant_id')::bigint as plant_id,
           nullif(r->>'pv_w',   '')::int as pv_w,
           nullif(r->>'load_w', '')::int as load_w,
           nullif(r->>'batt_w', '')::int as batt_w,
           nullif(r->>'grid_w', '')::int as grid_w,
           nullif(r->>'soc',    '')::int as soc,
           coalesce((r->>'partial')::boolean, false) as partial
      from jsonb_array_elements(coalesce(p_agg, '[]'::jsonb)) r
     where r->>'plant_id' is not null
  loop
    plant_list := plant_list || a.plant_id;

    select max(ts) into prev_ts from public.agg_minute where plant_id = a.plant_id;
    if prev_ts is not null and p_ts - prev_ts > 90 then
      insert into private.gaps (plant_id, from_ts, to_ts) values (a.plant_id, prev_ts, p_ts)
      on conflict (plant_id, from_ts) do nothing;
      gaps := gaps || a.plant_id;
      -- SOLAR-378: a hole over 10 minutes is refilled by first_load_continue.
      if p_ts - prev_ts > 600 then
        insert into private.refill_queue (plant_id) values (a.plant_id)
        on conflict (plant_id) do nothing;
      end if;
    end if;

    insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
    values (a.plant_id, p_ts, a.pv_w, a.load_w, a.batt_w, a.grid_w, a.soc,
            case when a.partial then 'poller_partial' else 'poller' end)
    on conflict (plant_id, ts) do nothing;
  end loop;

  perform public.meta_upsert(coalesce(p_meta, '[]'::jsonb));
  perform public.inverters_seed(coalesce(p_inverters, '[]'::jsonb));
  -- the newer token wins: a shard that started on an older token (it slept up to 20 s)
  -- must not overwrite one renewed since (SOLAR-649)
  perform plants.tokens_saved(jsonb_build_array(jsonb_build_object('account', p_account, 'access', p_access, 'expires', p_expires)));
  -- The other logins that can see these plant_list were served this minute too.
  perform plants.logins_served(plant_list, array[p_account]);

  return jsonb_build_object(
    'readings', n_readings,
    'strings',  n_strings,
    'plants',   to_jsonb(plant_list),
    'gaps',     to_jsonb(gaps));
end;
$function$;

CREATE OR REPLACE FUNCTION public.poll_commit_batch(p_ts bigint, p_rows jsonb, p_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(i integer, account uuid, result jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
declare
  accts uuid[];
  x uuid;
  t text;
  pl record;
begin
  if not billing.is_live() then
    raise exception 'poll_commit_batch needs billing live (0252)' using errcode = '55000';
  end if;
  -- a second batch in one transaction: the first one's tables are still there
  foreach t in array array['_bin', '_bok', '_brd', '_brw', '_bst', '_bsw', '_bme', '_bag', '_bgap'] loop
    if to_regclass('pg_temp.' || t) is not null then execute format('drop table pg_temp.%I', t); end if;
  end loop;

  create temp table _bin on commit drop as
    select e.n::int as i, (e.x->>'account')::uuid as account,
           coalesce(nullif(e.x->'versions', 'null'), '{}') as versions,
           e.x->>'access' as access, (e.x->>'expires')::bigint as expires,
           coalesce(nullif(e.x->'readings',  'null'), '[]') as readings,
           coalesce(nullif(e.x->'strings',   'null'), '[]') as strings,
           coalesce(nullif(e.x->'agg',       'null'), '[]') as agg,
           coalesce(nullif(e.x->'meta',      'null'), '[]') as meta,
           coalesce(nullif(e.x->'inverters', 'null'), '[]') as inverters
      from jsonb_array_elements(coalesce(p_rows, '[]')) with ordinality e (x, n);
  if exists (select 1 from _bin b where b.account is null) then
    raise exception 'poll_commit_batch: a row has no account' using errcode = '22023';
  end if;
  accts := array(select distinct b.account from _bin b order by 1);

  -- 1. logins: account_mark's locks, then the rows, in id order
  foreach x in array accts loop
    perform pg_advisory_xact_lock(1, hashtext(x::text));
  end loop;
  perform 1 from plants.login_info sa where sa.id = any (accts) order by sa.id for update;
  -- the newer token wins (0250): the last object with the latest expiry, when not older than the stored one
  perform plants.tokens_saved((select coalesce(jsonb_agg(jsonb_build_object('account', t.account, 'access', t.access, 'expires', t.expires)), '[]'::jsonb)
                                 from (select distinct on (b.account) b.account, b.access, b.expires from _bin b
                                        order by b.account, b.expires desc nulls last, b.i desc) t));

  -- 2. plants in id order, for share; a plant whose history was deleted for no key update,
  -- since step 8 updates it (two batches holding it for share would deadlock there). Then
  -- the version each read started on (looked up under the plant's own id, as write_allowed
  -- does) and read_now.
  for pl in select bp.id, (select f.history_purged_at from billing.plant_facts f where f.plant = bp.id) is not null as purged from plants.plant_info bp
            where bp.id in (select k::bigint from _bin b cross join jsonb_object_keys(b.versions) k)
            order by bp.id loop
    if pl.purged then
      perform 1 from plants.plant_info where id = pl.id for no key update;
    else
      perform 1 from plants.plant_info where id = pl.id for share;
    end if;
  end loop;
  create temp table _bok on commit drop as
    with v as (select distinct b.i, k::bigint as plant, b.versions->>(k::bigint::text) as version
                 from _bin b cross join jsonb_object_keys(b.versions) k)
    select v.i, v.plant from v
     where v.plant in (select pr from billing.plants_read_now(array(select distinct plant from v), greatest(p_at, clock_timestamp())) pr)   -- R20: the database's clock, after the locks
       and exists (select 1 from plants.plant_info bp where bp.id = v.plant and bp.version = v.version::bigint);
  -- one object sending an inverter twice fails in poll_commit_v2 (on conflict cannot update a
  -- row twice); here too, so the caller's login-by-login save fails that login alone
  if exists (select 1 from _bin b cross join jsonb_array_elements(b.inverters) e
              group by b.i, e->>'sn' having count(*) > 1)
     or exists (select 1 from _bin b cross join jsonb_array_elements(b.meta) e
                 where (e->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i)
                 group by b.i, e->>'sn' having count(*) > 1) then
    raise exception 'poll_commit_batch: an inverter twice in one row' using errcode = '21000';
  end if;

  perform set_config('billing.guarded', 'on', true);

  -- 3. readings
  create temp table _brd on commit drop as
    select b.i, e.n, jsonb_populate_record(null::public.readings, e.v) as rw
      from _bin b cross join jsonb_array_elements(b.readings) with ordinality e (v, n)
     where (e.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i);
  delete from _brd where (rw).plant_id is null;
  create temp table _brw on commit drop as
    select distinct on ((d.rw).ts, (d.rw).sn) d.rw from _brd d
     order by (d.rw).ts, (d.rw).sn, case when (d.rw).ts = p_ts then -d.i else d.i end, d.n;
  perform 1 from public.readings r join _brw w on r.ts = (w.rw).ts and r.sn = (w.rw).sn
   where r.ts = p_ts order by r.ts, r.sn for update of r;
  delete from public.readings r using _brw w where r.ts = p_ts and r.ts = (w.rw).ts and r.sn = (w.rw).sn;
  insert into public.readings select (w.rw).* from _brw w order by (w.rw).ts, (w.rw).sn on conflict do nothing;

  -- 4. strings: used_strings, string_slots, unused inputs dropped (0061), then as readings
  create temp table _bst on commit drop as
    select b.i, e.n, jsonb_populate_record(null::public.strings, e.v) as rw
      from _bin b cross join jsonb_array_elements(b.strings) with ordinality e (v, n)
     where (e.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i);
  delete from _bst where (rw).plant_id is null;
  perform 1 from plants.meta_info m
   where m.sn in (select (t.rw).sn from _bst t
                  union select e->>'sn' from _bin b cross join jsonb_array_elements(b.meta) e)
   order by m.sn for no key update;
  -- poll_commit_v2 updates an inverter's string records only once its meta row exists: from the
  -- batch's start (avail 0), or from the object after the first one that sent its meta
  create temp table _bme on commit drop as
    select m.sn, 0 as avail from plants.meta_info m where m.sn in (select (t.rw).sn from _bst t);
  insert into _bme
  select e->>'sn', min(b.i) + 1 from _bin b cross join jsonb_array_elements(b.meta) e
   where (e->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i)
     and e->>'sn' in (select (t.rw).sn from _bst t) and e->>'sn' not in (select sn from _bme)
   group by e->>'sn';
  -- meta (only plants written), the last object winning, in sn order; ord and status: the last sent
  perform public.meta_upsert(coalesce((
    select jsonb_agg(m.v || jsonb_build_object('ord', m.ord, 'status', m.status) order by m.sn)
      from (select distinct on (q.v->>'sn') q.v->>'sn' as sn, q.v,
                   (select r.v->>'ord' from (select b2.i, e2.n, e2.v from _bin b2 cross join jsonb_array_elements(b2.meta) with ordinality e2 (v, n)) r
                     where r.v->>'sn' = q.v->>'sn' and nullif(r.v->>'ord', '') is not null
                       and (r.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = r.i)
                     order by r.i desc, r.n desc limit 1) as ord,
                   (select r.v->>'status' from (select b2.i, e2.n, e2.v from _bin b2 cross join jsonb_array_elements(b2.meta) with ordinality e2 (v, n)) r
                     where r.v->>'sn' = q.v->>'sn' and nullif(r.v->>'status', '') is not null
                       and (r.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = r.i)
                     order by r.i desc, r.n desc limit 1) as status
              from (select b.i, e.n, e.v from _bin b cross join jsonb_array_elements(b.meta) with ordinality e (v, n)
                     where (e.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i)) q
             order by q.v->>'sn', q.i desc, q.n desc) m), '[]'));
  -- the input count of the last object that sent the inverter once its meta row existed
  update private.meta m set string_slots = c.n
    from (select distinct on (q.sn) q.sn, q.n from
            (select (t.rw).sn as sn, t.i, count(*)::int as n from _bst t
              where t.i >= (select x.avail from _bme x where x.sn = (t.rw).sn) group by 1, 2) q
           order by q.sn, q.i desc) c
   where m.sn = c.sn and m.string_slots is distinct from c.n;
  -- unused inputs dropped as poll_commit_v2 does object by object: a dead input stays only when
  -- used before the batch, or live in this or an earlier object once the meta row existed
  delete from _bst t
   where not private.string_live((t.rw).volt_v, (t.rw).current_a, (t.rw).power_w, (t.rw).today_kwh)
     and not exists (select 1 from plants.meta_info m join _bme x on x.sn = m.sn
                      where m.sn = (t.rw).sn and x.avail <= t.i
                        and ((t.rw).no = any (m.used_strings)
                             or exists (select 1 from _bst t2
                                         where (t2.rw).sn = (t.rw).sn and (t2.rw).no = (t.rw).no
                                           and t2.i between x.avail and t.i
                                           and private.string_live((t2.rw).volt_v, (t2.rw).current_a,
                                                                   (t2.rw).power_w, (t2.rw).today_kwh))));
  update private.meta m
     set used_strings = (select array_agg(distinct y order by y)
                           from unnest(m.used_strings || array(
                             select (t.rw).no from _bst t
                              where (t.rw).sn = m.sn and t.i >= (select x.avail from _bme x where x.sn = m.sn)
                                and private.string_live((t.rw).volt_v, (t.rw).current_a, (t.rw).power_w, (t.rw).today_kwh))) y)
   where exists (select 1 from _bst t
                  where (t.rw).sn = m.sn and not ((t.rw).no = any (m.used_strings))
                    and t.i >= (select x.avail from _bme x where x.sn = m.sn)
                    and private.string_live((t.rw).volt_v, (t.rw).current_a, (t.rw).power_w, (t.rw).today_kwh));
  create temp table _bsw on commit drop as
    select distinct on ((d.rw).ts, (d.rw).sn, (d.rw).no) d.rw from _bst d
     order by (d.rw).ts, (d.rw).sn, (d.rw).no, case when (d.rw).ts = p_ts then -d.i else d.i end, d.n;
  perform 1 from public.strings s join _bsw w on s.ts = (w.rw).ts and s.sn = (w.rw).sn and s.no = (w.rw).no
   where s.ts = p_ts order by s.ts, s.sn, s.no for update of s;
  delete from public.strings s using _bsw w
   where s.ts = p_ts and s.ts = (w.rw).ts and s.sn = (w.rw).sn and s.no = (w.rw).no;
  insert into public.strings select (w.rw).* from _bsw w order by (w.rw).ts, (w.rw).sn, (w.rw).no on conflict do nothing;

  -- 5. plant minutes: gaps from max(ts) before the batch, first write wins
  create temp table _bag on commit drop as
    select b.i, e.n, (e.v->>'plant_id')::bigint as plant,
           nullif(e.v->>'pv_w',   '')::int as pv_w,
           nullif(e.v->>'load_w', '')::int as load_w,
           nullif(e.v->>'batt_w', '')::int as batt_w,
           nullif(e.v->>'grid_w', '')::int as grid_w,
           nullif(e.v->>'soc',    '')::int as soc,
           coalesce((e.v->>'partial')::boolean, false) as partial
      from _bin b cross join jsonb_array_elements(b.agg) with ordinality e (v, n)
     where e.v->>'plant_id' is not null
       and (e.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i);
  create temp table _bgap on commit drop as
    select p.plant, p.first_i, (select max(a.ts) from public.agg_minute a where a.plant_id = p.plant) as prev
      from (select g.plant, min(g.i) as first_i from _bag g group by g.plant) p;
  insert into private.gaps (plant_id, from_ts, to_ts)
  select g.plant, g.prev, p_ts from _bgap g where g.prev is not null and p_ts - g.prev > 90 order by g.plant
  on conflict (plant_id, from_ts) do nothing;
  -- SOLAR-378: a hole over 10 minutes is refilled by first_load_continue
  insert into private.refill_queue (plant_id)
  select g.plant from _bgap g where g.prev is not null and p_ts - g.prev > 600 order by g.plant
  on conflict (plant_id) do nothing;
  insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
  select distinct on (g.plant) g.plant, p_ts, g.pv_w, g.load_w, g.batt_w, g.grid_w, g.soc,
         case when g.partial then 'poller_partial' else 'poller' end
    from _bag g order by g.plant, g.i, g.n
  on conflict (plant_id, ts) do nothing;

  -- 6. inverters (all), the last object winning, in sn order
  perform public.inverters_seed(coalesce((
    select jsonb_agg(m.v order by m.sn)
      from (select distinct on (e.v->>'sn') e.v->>'sn' as sn, e.v
              from _bin b cross join jsonb_array_elements(b.inverters) with ordinality e (v, n)
             order by e.v->>'sn', b.i desc, e.n desc) m), '[]'));

  -- 7. the other logins that see these plants were served this minute too
  perform plants.logins_served(array(select g.plant from _bag g), accts);
  perform set_config('billing.guarded', 'off', true);

  -- 8. new readings on a deleted plant: it has history again (0246)
  update billing.plant_facts bp set history_purged_at = null
   where bp.history_purged_at is not null
     and exists (select 1 from _bok o join _bin b on b.i = o.i
                  where o.plant = bp.plant
                    and (exists (select 1 from jsonb_array_elements(b.readings) e where (e->>'plant_id')::bigint = bp.plant)
                         or exists (select 1 from jsonb_array_elements(b.agg) e where (e->>'plant_id')::bigint = bp.plant)));

  return query
  select b.i, b.account, jsonb_build_object(
           'readings', (select count(*) from _brd d where d.i = b.i)::int,
           'strings',  (select count(*) from _bst t where t.i = b.i)::int,
           'plants',   to_jsonb(array(select g.plant from _bag g where g.i = b.i order by g.n)),
           'gaps',     to_jsonb(array(select g.plant from _bgap g
                                       where g.first_i = b.i and g.prev is not null and p_ts - g.prev > 90
                                       order by (select min(a.n) from _bag a where a.i = b.i and a.plant = g.plant))),
           'refused',  to_jsonb(array(select k::bigint from jsonb_object_keys(b.versions) k
                                       where k::bigint not in (select o.plant from _bok o where o.i = b.i) order by 1)))
    from _bin b order by b.i;
end $function$;

CREATE OR REPLACE FUNCTION public.poll_commit_v2(p_versions jsonb, p_account uuid, p_ts bigint, p_readings jsonb, p_strings jsonb, p_agg jsonb, p_meta jsonb, p_inverters jsonb, p_access text, p_expires bigint, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
declare
  ok bigint[];
  out jsonb;
  pl record;
begin
  if not billing.is_live() then
    return public.poll_commit(p_account, p_ts, p_readings, p_strings, p_agg, p_meta, p_inverters, p_access, p_expires);
  end if;
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  for pl in select bp.id, (select f.history_purged_at from billing.plant_facts f where f.plant = bp.id) is not null as purged from plants.plant_info bp
             where bp.id in (select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k)
             order by bp.id loop
    if pl.purged then
      perform 1 from plants.plant_info where id = pl.id for no key update;
    else
      perform 1 from plants.plant_info where id = pl.id for share;
    end if;
  end loop;
  ok := billing.write_allowed(p_versions, greatest(p_at, clock_timestamp()));   -- R20: the database's clock, after the locks
  -- the token is saved whatever happens to the readings: the fetch may have refreshed it
  perform set_config('billing.guarded', 'on', true);
  out := public.poll_commit(p_account, p_ts, billing.only_plants(p_readings, ok), billing.only_plants(p_strings, ok),
                            billing.only_plants(p_agg, ok), billing.only_plants(p_meta, ok), p_inverters,
                            p_access, p_expires);
  perform set_config('billing.guarded', 'off', true);
  -- new readings on a deleted plant: it has history again, so the delete date and "History
  -- deleted" go
  update billing.plant_facts set history_purged_at = null
   where history_purged_at is not null and plant = any (ok)
     and plant in (select (e->>'plant_id')::bigint from jsonb_array_elements(coalesce(p_readings, '[]'::jsonb)) e
                union select (e->>'plant_id')::bigint from jsonb_array_elements(coalesce(p_agg, '[]'::jsonb)) e);
  return out || jsonb_build_object('refused', to_jsonb(array(
    select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k where k::bigint <> all (ok) order by 1)));
end $function$;

CREATE OR REPLACE FUNCTION public.poll_jobs_v2(p_shard integer, p_shards integer, p_account uuid DEFAULT NULL::uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(plant_id bigint, plant_name text, timezone text, batt_positive_means text, backfill_next text, backfill_until text, backfill_tries integer, temp_next text, temp_tries integer, has_grid boolean, account_id uuid, user_id uuid, username text, access_token text, access_expires_at bigint, plant_version bigint, brand text, vendor_plant_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  return query
  with pick as (
    select distinct on (r.plant) r.plant, r.lane
      from billing.reading_routes(p_at) r
     order by r.plant, r.via_share, r.since, r.lane
  )
  select p.plant,
         (select lp.plant_name from plants.list_info lp
           where lp.plant = p.plant and lp.plant_name is not null order by lp.last_seen_at desc nulls last limit 1),
         bp.time_zone, c.batt_positive_means,
         c.backfill_next::text, c.backfill_until::text, coalesce(c.backfill_tries, 0),
         c.temp_next::text, coalesce(c.temp_tries, 0), c.has_grid,
         sa.id, sa.user_id, sa.username, tk.access_token, tk.access_expires_at,
         bp.version, bp.brand, bp.vendor_id
    from pick p
    join plants.login_info sa on sa.id = p.lane
    join plants.login_tokens tk on tk.id = sa.id
    join plants.plant_info bp on bp.id = p.plant
    left join plants.settings c on c.plant_id = p.plant
   where case when p_account is not null then sa.id = p_account
              else ('x' || lpad(substr(replace(sa.id::text, '-', ''), 1, 8), 16, '0'))::bit(64)::bigint
                   % greatest(1, p_shards) = p_shard end
   order by p.plant;
end $function$;

CREATE OR REPLACE FUNCTION public.poll_routes(p_seconds integer[], p_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(plant_id bigint, account_id uuid, plant_version bigint, timezone text, batt_positive_means text, has_grid boolean, ends_at timestamp with time zone, read_second integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with pick as (
    select distinct on (r.plant) r.plant, r.lane, r.ends_at
      from billing.reading_routes_set(p_at) r
     order by r.plant, r.via_share, r.since, r.lane
  ), pk as (
    select p.plant, p.lane, p.ends_at, bp.version from pick p join plants.plant_info bp on bp.id = p.plant
  ), lane_inv as (
    select pk.lane, count(i.sn) as n
      from pk left join plants.inverter_info i on i.plant_id = pk.plant
     group by pk.lane
  ), sec as (
    select pk.*, case when sa.kind = 'share' or li.n > 10 then private.read_second(pk.plant::text)
                      else private.read_second(pk.lane::text) end as s
      from pk
      join plants.login_info sa on sa.id = pk.lane
      join lane_inv li on li.lane = pk.lane
  )
  select sec.plant, sec.lane, sec.version, plants.tz(sec.plant), c.batt_positive_means,
         c.has_grid, sec.ends_at, sec.s
    from sec left join plants.settings c on c.plant_id = sec.plant
   where sec.s = any (p_seconds)
   order by sec.plant
$function$;

CREATE OR REPLACE FUNCTION public.q_grid_present(p_plant bigint, p_ts bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with voters as (
    select grid_volt_v, device_time
      from public.readings
     where plant_id = p_plant
       and ts = p_ts
       and grid_volt_v is not null
  ),
  newest as (
    -- NULL device_time cannot be dated, so it never wins. When every voter is
    -- undated -- readings from before 0031 stored device_time -- max() is NULL
    -- and the `is not distinct from` below lets them all vote, which is the old
    -- behaviour and the only thing left to do with them.
    select max(device_time) as dt from voters
  )
  select case when not exists (select 1 from voters) then null
              else (select bool_or(public.grid_live(v.grid_volt_v))
                      from voters v
                     where v.device_time
                           is not distinct from (select dt from newest)) end
$function$;

CREATE OR REPLACE FUNCTION public.q_missing_minutes(p_plant bigint, p_day date)
 RETURNS TABLE(ts bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with b as (
    select (select min(a.ts) from public.agg_minute a where a.plant_id = p_plant) as first_ts,
           (select public.day_start_epoch_tz(c.backfill_next, public.plant_tz(p_plant))
              from plants.settings c where c.plant_id = p_plant and c.backfill_next is not null) as bf_ts,
           public.day_start_epoch_tz(p_day, public.plant_tz(p_plant))            as day_start,
           extract(epoch from now())::bigint                                    as now_ts
  ),
  bounds as (
    select ceil(greatest(day_start, least(first_ts, bf_ts)) / 60.0)::bigint * 60 as lo,
           least(day_start + 86400, now_ts - 600)                                as hi
      from b where first_ts is not null or bf_ts is not null
  )
  select g as ts from bounds, generate_series(bounds.lo, bounds.hi - 60, 60) g
   where bounds.hi > bounds.lo
     and not exists (select 1 from public.agg_minute a where a.plant_id = p_plant and a.ts = g
                                                  and a.source <> 'poller_partial')
   order by g
$function$;

CREATE OR REPLACE FUNCTION public.share_account_set(p_user uuid, p_username text, p_access text, p_expires bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare acc uuid;
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  select id into acc from plants.logins where kind = 'share' and brand = plants.default_brand();
  if acc is null then
    insert into plants.logins (user_id, account, brand, kind, username, status, access_token, access_expires_at, last_ok_at)
    values (p_user, null, plants.default_brand(), 'share', p_username, 'ok', p_access, p_expires, now())
    returning id into acc;
  else
    perform pg_advisory_xact_lock(1, hashtext(acc::text));
    update plants.logins set username = p_username, access_token = p_access, access_expires_at = p_expires,
                             status = 'ok', last_error = null, last_ok_at = now()
     where id = acc;
  end if;
  return acc;
end
$function$;

CREATE OR REPLACE FUNCTION public.share_claim_any(p_user uuid, p_account uuid, p_plant text, p_plant_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  vendor text := btrim(p_plant);   -- the brand's id for the plant (R11)
  v_brand text;
  pid bigint;
  acc uuid;
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  select l.brand into v_brand from plants.logins l where l.id = p_account and l.kind = 'share' and l.status <> 'disabled';
  if not found then raise exception 'share_claim: % is not the share login', p_account; end if;
  acc := billing.account_of(p_user);
  select p.id into pid from plants.plants p where p.brand = v_brand and p.vendor_id = vendor;
  -- the user reads it already: through their own login, or a claim whose share row is live (a
  -- claim with its row missing is repaired below)
  if pid is not null and (exists (select 1 from plants.user_plants u where u.plant_id = pid and u.user_id = p_user
                                     and not u.via_share and u.share_gone_at is null)
                          or (exists (select 1 from plants.claims c where c.plant = pid and c.account = acc)
                              and exists (select 1 from plants.login_plants lp where lp.login = p_account and lp.plant = pid
                                             and lp.gone_at is null))) then
    return jsonb_build_object('result', 'yours', 'plant', pid);
  end if;
  pid := plants.claim(acc, v_brand, vendor, p_plant_name);
  -- a lapsed claim by someone else: its queued mail goes
  delete from public.email_queue q where q.plant_id = pid and q.status = 'queued'
     and q.user_id <> p_user and q.kind like 'share_%';
  return jsonb_build_object('result', 'claimed', 'plant', pid);
end
$function$;

CREATE OR REPLACE FUNCTION public.share_retry_due()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select a.id from plants.logins a
   where a.kind = 'share' and a.status = 'needs_reconnect'
     and coalesce((select max(e.at) from plants.login_events e
                    where e.account_id = a.id and e.event = 'died'), '-infinity') < now() - interval '55 minutes'
$function$;

CREATE OR REPLACE FUNCTION public.soc_at(p_plant bigint, p_at bigint)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select round(a.soc)::int from public.agg_minute a
   where a.plant_id = p_plant and a.ts between p_at - 600 and p_at and a.soc is not null
   order by a.ts desc limit 1
$function$;

CREATE OR REPLACE FUNCTION public.span_figures(p_plant bigint, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
           'made_kwh', coalesce(sum(e.pv_kwh), 0), 'home_kwh', coalesce(sum(e.load_kwh), 0),
           'import_kwh', coalesce(sum(e.imp_kwh), 0),
           'independence_pct', public.independence_pct(coalesce(sum(e.load_kwh), 0), coalesce(sum(e.imp_kwh), 0)))
    from public._plant_day_energy(p_plant, p_from, p_to) e
   -- a day of zeros is the brand's filler for a day with no readings (notify hasData)
   where coalesce(e.load_kwh, 0) > 0 or coalesce(e.pv_kwh, 0) > 0
$function$;

CREATE OR REPLACE FUNCTION public.sync_logins()
 RETURNS TABLE(id uuid, user_id uuid, username text, brand text, access_token text, access_expires_at bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select l.id, l.user_id, l.username, l.brand, l.access_token, l.access_expires_at
    from plants.logins l where l.status = 'ok' order by l.id
$function$;

-- ---------------------------------------------------------------------------
-- the old copies go (R3, R7, R24)
drop function billing.link_login(uuid, text, text, uuid, jsonb, timestamptz, text, uuid);
drop function billing.login_seen(uuid, jsonb, timestamptz);
drop function billing.claim_plant(uuid, bigint, text, text, timestamptz, text);
drop function billing.unclaim(uuid, bigint[], timestamptz, text);
drop function billing.remove_login(uuid, uuid, timestamptz, text);
drop function public.plant_users_upsert(uuid, uuid, jsonb);
drop function public.share_sync(uuid, bigint[]);
drop function public.share_claim(uuid, uuid, bigint, text);
drop function public.share_claim_live(uuid, uuid, bigint, text);
drop function public.api_link_disconnect(uuid);
drop function private.share_release(uuid, uuid);
drop function private.billing_drop_plant(uuid, bigint);
drop table public.plant_users;
drop function private.email_on_plant_user();
drop table private.sunsynk_accounts;
drop function billing.login_status_follow();
drop function private.plants_tombstone(bigint[]);

-- SOLAR-681 R17: a brand's outage and its call counts are its own. One brand's cloud going
-- down no longer mutes another brand's plants' alerts (email_system_state was one row, 0174:126).
--   plants.brand_state  per brand: down, outage id, since, up at (was private.email_system_state)
--   plants.brand_calls  per brand and day (was private.sunsynk_calls); brand '' holds the
--                       reader's own run log (kind poll_run)
--   last_try 'sunsynk' -> 'vendor': the brand's fault, whatever the brand
-- One transaction, compared before the old ones go (R25).

create or replace function plants.market_tz() returns text
  language sql stable set search_path to '' as $$
  select m.default_time_zone from billing.markets m order by m.code limit 1
$$;

create sequence plants.outage_id_seq;
create table plants.brand_state (
  brand       text primary key references plants.brands (code),
  down        boolean not null default false,
  outage_id   bigint not null default 0,
  down_since  bigint,
  up_at       timestamptz,
  clear_since timestamptz
);
insert into plants.brand_state (brand, down, outage_id, down_since, up_at, clear_since)
select plants.default_brand(), s.sunsynk_down, s.outage_id, s.down_since, s.up_at, s.clear_since
  from private.email_system_state s where s.id = 1;
insert into plants.brand_state (brand) select code from plants.brands on conflict do nothing;
select setval('plants.outage_id_seq', greatest(1, (select max(outage_id) from plants.brand_state)));
do $$
begin
  if exists (select 1 from private.email_system_state s left join plants.brand_state b on b.brand = plants.default_brand()
              where (s.sunsynk_down, s.outage_id, s.down_since, s.up_at, s.clear_since)
                    is distinct from (b.down, b.outage_id, b.down_since, b.up_at, b.clear_since)) then
    raise exception 'brand_state: copy differs from email_system_state';
  end if;
end $$;

alter table private.sunsynk_calls set schema plants;
alter table plants.sunsynk_calls rename to brand_calls;
alter table plants.brand_calls add column brand text not null default '';
update plants.brand_calls set brand = plants.default_brand() where kind <> 'poll_run';
alter table plants.brand_calls drop constraint sunsynk_calls_pkey,
  add constraint brand_calls_pkey primary key (day, brand, kind, result);

alter table plants.logins drop constraint logins_last_try_check;
update plants.logins set last_try = 'vendor' where last_try = 'sunsynk';
alter table plants.logins add constraint logins_last_try_check check (last_try in ('ok', 'vendor', 'ours'));

delete from private.job_checks where name = 'sunsynk';   -- the check is "vendor" now

do $$
declare t text;
begin
  foreach t in array array['brand_state', 'brand_calls'] loop
    execute format('alter table plants.%I enable row level security', t);
    execute format('revoke all on table plants.%I from public, anon, authenticated', t);
  end loop;
end $$;
revoke all on function plants.market_tz() from public, anon, authenticated;

-- doors for other parts (R2)
-- brand calls on a day, and how many of them failed on the brand's side
create or replace function plants.calls_on(p_day date) returns table (calls bigint, failed bigint)
  language sql stable security definer set search_path to '' as $$
  select coalesce(sum(k.calls), 0)::bigint,
         coalesce(sum(k.calls) filter (where k.result in ('429', '403_throttle', '5xx', 'network', 'timeout')), 0)::bigint
    from plants.brand_calls k where k.day = p_day and k.brand <> ''
$$;
-- the reader's shard's last run since a day (its run log rows, brand '')
create or replace function plants.run_last_at(p_shard integer, p_since date) returns timestamptz
  language sql stable security definer set search_path to '' as $$
  select max(k.last_at) from plants.brand_calls k
   where k.brand = '' and k.kind = 'poll_run' and k.result = 's' || p_shard and k.day >= p_since
$$;
revoke all on function plants.calls_on(date), plants.run_last_at(integer, date) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.email_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  now_s bigint := extract(epoch from now())::bigint;
  b plants.brand_state;
  tried int;
  failing int;
  t_all int := 0;
  f_all int := 0;
  down boolean;
  r record;
  n_stale int := 0;
  n_rep int := 0;
begin
  -- Each brand's cloud on its own (R17): one brand's outage never mutes another's alerts. A
  -- login counts when poll tried it in the last 10 minutes; it is failing when its last try
  -- was the brand's fault and nothing good came for 10 min. Down: over half failing, and at
  -- least 3 of them, or all of them when fewer than 3 were tried (0119). Back once not down
  -- for 15 min (0151). Outage ids come from one sequence, so mail keys never meet across brands.
  for b in select * from plants.brand_state order by brand for update loop
    select count(*) filter (where a.last_try_at > now() - interval '10 minutes'),
           count(*) filter (where a.last_try_at > now() - interval '3 minutes' and a.last_try = 'vendor'
                              and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes')
      into tried, failing
      from plants.logins a where a.status = 'ok' and a.brand = b.brand;
    t_all := t_all + tried; f_all := f_all + failing;
    down := failing >= least(3, tried) and failing > 0 and failing * 2 > tried;

    if down and not b.down then
      b.down := true; b.outage_id := nextval('plants.outage_id_seq'); b.clear_since := null;
      b.down_since := (select extract(epoch from min(coalesce(a.last_ok_at, a.linked_at)))::bigint
                         from plants.logins a
                        where a.status = 'ok' and a.brand = b.brand and a.last_try = 'vendor'
                          and a.last_try_at > now() - interval '3 minutes'
                          and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes');
    elsif down then
      b.clear_since := null;
    elsif b.down then
      b.clear_since := coalesce(b.clear_since, now());
      if b.clear_since <= now() - interval '15 minutes' then
        -- Back: everyone told it was down hears it is back.
        insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
        select q.user_id, q.plant_id, 'sunsynk_back', 'sunsynk_back:' || b.outage_id, q.key,
               jsonb_build_object('since', b.down_since, 'at', extract(epoch from b.clear_since)::bigint), 0
          from public.email_queue q
         where q.key = 'sunsynk_down:' || b.outage_id
        on conflict do nothing;
        b.down := false; b.up_at := now(); b.clear_since := null;
      end if;
    end if;
    if b.down then
      -- Users on a failing login; one email each, about their first plant on it.
      -- Run every minute of the outage, so a login that fails later is told too.
      insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
      select distinct on (pu.user_id) pu.user_id, pu.plant_id, 'sunsynk_down', 'sunsynk_down:' || b.outage_id,
             jsonb_build_object('since', b.down_since), 0
        from plants.logins a join plants.user_plants pu on pu.account_id = a.id
       where a.status = 'ok' and a.brand = b.brand and a.last_try = 'vendor' and a.last_try_at > now() - interval '3 minutes'
         and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes'
         and private.plant_live(pu.user_id, pu.plant_id)                          -- 0256
       order by pu.user_id, pu.linked_at
      on conflict do nothing;
    end if;
    update plants.brand_state set down = b.down, outage_id = b.outage_id, down_since = b.down_since,
           up_at = b.up_at, clear_since = b.clear_since
     where brand = b.brand;
  end loop;

  -- No readings: 30 min since the brand's newest reading for the plant, while poll
  -- still tries a login on it (ours not running is not the inverter going quiet),
  -- and not during an outage of the plant's brand (that has its own email) nor in the
  -- 15 min after one, while readings that the outage held up come back. A plant started
  -- again gets 30 min from the start, as a new link does (0174).
  begin
    for r in
      select s.plant_id, s.last_dev from private.plant_alert_state s
       where not s.stale and s.last_dev < now_s - 1800 and not coalesce(s.started_at between now_s - 1800 and now_s, false)   -- 0174
         and exists (select 1 from plants.brand_state bs
                      where bs.brand = plants.brand_of(s.plant_id) and not bs.down and (bs.up_at is null or bs.up_at < now() - interval '15 minutes'))
         and exists (select 1 from plants.user_plants pu join plants.logins a on a.id = pu.account_id
                      where pu.plant_id = s.plant_id and a.status = 'ok' and a.last_try in ('ok', 'vendor')
                        and a.last_try_at > now() - interval '3 minutes')
       for update of s skip locked
    loop
      update private.plant_alert_state set stale = true, stale_key = 'logger_stale:' || r.plant_id || ':' || r.last_dev,
             stale_clear_at = null
       where plant_id = r.plant_id;
      perform private.email_enqueue_plant(r.plant_id, 'logger_stale', 'logger_stale:' || r.plant_id || ':' || r.last_dev,
        jsonb_build_object('since', r.last_dev));
      n_stale := n_stale + 1;
    end loop;
    -- One inverter quiet for 30 min while another on the plant still reports (0119).
    -- An inverter no longer on the plant is left alone.
    for r in
      select i.plant_id, i.sn, i.last_dev, coalesce(nullif(m.alias, ''), 'Inverter ' || i.sn) as inverter
        from private.inverter_alert_state i
        join private.plant_alert_state s on s.plant_id = i.plant_id
        left join private.meta m on m.sn = i.sn
       where not i.stale and i.last_dev < now_s - 1800 and not coalesce(s.started_at between now_s - 1800 and now_s, false)   -- 0174
         and not s.stale and s.last_dev >= now_s - 900
         and exists (select 1 from private.inverters v where v.sn = i.sn and v.plant_id = i.plant_id)
         and exists (select 1 from plants.brand_state bs
                      where bs.brand = plants.brand_of(i.plant_id) and not bs.down and (bs.up_at is null or bs.up_at < now() - interval '15 minutes'))
         and exists (select 1 from plants.user_plants pu join plants.logins a on a.id = pu.account_id
                      where pu.plant_id = i.plant_id and a.status = 'ok' and a.last_try in ('ok', 'vendor')
                        and a.last_try_at > now() - interval '3 minutes')
       for update of i skip locked
    loop
      update private.inverter_alert_state set stale = true, stale_key = 'logger_stale:' || r.plant_id || ':' || r.sn || ':' || r.last_dev,
             clear_at = null
       where plant_id = r.plant_id and sn = r.sn;
      perform private.email_enqueue_plant(r.plant_id, 'logger_stale', 'logger_stale:' || r.plant_id || ':' || r.sn || ':' || r.last_dev,
        jsonb_build_object('since', r.last_dev, 'inverter', r.inverter));
      n_stale := n_stale + 1;
    end loop;
  end;

  -- No once-a-day repeat while battery hot, uneven charge or panels stopped last: each
  -- has its "back" note now (0151).

  -- Reports from 07:00 local: weekly on Monday, monthly on the 1st, yearly on 1 January,
  -- for plants linked by the first day of the period they cover (private.reports_due).
  with ins as (
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    select user_id, plant_id, 'report_' || period, 'report_' || period || ':' || plant_id || ':' || d,
           jsonb_build_object('today', d), 2
      from private.reports_due(now())
    on conflict do nothing
    returning 1
  )
  select count(*) into n_rep from ins;

  return jsonb_build_object('down', (select coalesce(jsonb_agg(x.brand order by x.brand), '[]') from plants.brand_state x where x.down),
                            'tried', t_all, 'failing', f_all,
                            'stale', n_stale, 'reports', n_rep);
end $function$;

CREATE OR REPLACE FUNCTION public.email_poll_step(p_ts bigint, p_outcomes jsonb, p_plants bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  todo bigint[];
  r record;
  clr bigint;
  failed jsonb := '[]'::jsonb;
begin
  update plants.logins a set last_try_at = now(), last_try = o.outcome
    from jsonb_to_recordset(coalesce(p_outcomes, '[]'::jsonb)) as o(account uuid, outcome text)
   where a.id = o.account and o.outcome in ('ok', 'vendor', 'ours');

  -- Plants with config (purged ones have none) not already stepped for this minute.
  -- The rows stay locked to the end, so a link kick polling the same account in the
  -- same minute waits here and then finds them stepped: strings are counted once.
  insert into private.plant_alert_state (plant_id)
  select c.plant_id from public.plant_config c where c.plant_id = any (coalesce(p_plants, '{}')) order by 1
  on conflict do nothing;
  select coalesce(array_agg(x.plant_id), '{}') into todo
    from (select s.plant_id from private.plant_alert_state s
           where s.plant_id = any (coalesce(p_plants, '{}')) and (s.stepped_ts is null or s.stepped_ts < p_ts)
           order by s.plant_id for update) x;

  -- Strings, all plants at once: a string with voltage is alive; one under 1.5 V and
  -- 5 W while another string on the plant makes over 200 W counts a dead sample, but
  -- only once the string itself has made over 200 W (an input with no panels never
  -- has; SOLAR-188). A string on another inverter counts only when both inverters
  -- reported in the last 10 min (poll carries an inverter's strings for 5 runs), so an
  -- inverter's only used string can stop and be seen (0231, SOLAR-613). A dead string
  -- stays dead until it has had voltage for 15 min with no dead sample (clear_at, 0151).
  insert into private.string_alert_state as st (plant_id, sn, no, last_alive, dead_n, made_power)
  with fresh as (
    select x.plant_id, x.sn
      from public.readings x join public.plant_config c on c.plant_id = x.plant_id
     where x.plant_id = any (todo) and x.ts = p_ts and x.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
     group by x.plant_id, x.sn
    having max(extract(epoch from (x.device_time::timestamp at time zone plants.tz(c.plant_id)))::bigint) >= p_ts - 600
  )
  select x.plant_id, x.sn, x.no, case when x.alive then p_ts end, 0, x.made
    from (select s.plant_id, s.sn, s.no, coalesce(s.volt_v, 0) >= 1.5 as alive,
                 coalesce(s.power_w, 0) > 200 as made,
                 coalesce(s.volt_v, 0) < 1.5 and coalesce(s.power_w, 0) < 5
                   and exists (select 1 from public.strings o where o.plant_id = s.plant_id and o.ts = p_ts
                                  and (o.sn, o.no) <> (s.sn, s.no) and coalesce(o.power_w, 0) > 200
                                  and (o.sn = s.sn
                                       or (exists (select 1 from fresh f where f.plant_id = s.plant_id and f.sn = s.sn)
                                           and exists (select 1 from fresh f where f.plant_id = o.plant_id and f.sn = o.sn)))) as dead_in_sun
            from public.strings s
           where s.plant_id = any (todo) and s.ts = p_ts) x
   where x.alive or x.dead_in_sun
  on conflict (plant_id, sn, no) do update set
    last_alive = coalesce(excluded.last_alive, st.last_alive),
    made_power = st.made_power or excluded.made_power,
    dead_n     = case when excluded.last_alive is not null or not st.made_power then 0
                      when st.dead then st.dead_n else st.dead_n + 1 end,
    clear_at   = case when st.dead and excluded.last_alive is not null then coalesce(st.clear_at, excluded.last_alive) end;
  -- Strings dead in the sun for 12 samples: one email each. When every string that has
  -- made power on an inverter stops in the same minute, that is one email for the
  -- inverter ("Strings 1 and 2"), kept on its lowest string; the others are marked with
  -- group_no and come back without an email of their own (0231).
  for r in
    with due as (
      select a.plant_id, a.sn, a.no, coalesce(a.last_alive + 60, p_ts - 900) as since
        from private.string_alert_state a
       where a.plant_id = any (todo) and not a.dead and a.dead_n >= 12
    ), inv as (
      select d.plant_id, d.sn, min(d.no) as first_no, count(*) as n,
             array_agg(d.no order by d.no) as nos
        from due d group by d.plant_id, d.sn
    ), whole as (
      select i.* from inv i
       where i.n >= 2
         and i.n = (select count(*) from private.string_alert_state a
                     where a.plant_id = i.plant_id and a.sn = i.sn and a.made_power and not a.dead)
    )
    select d.plant_id, d.sn, d.no, d.since, w.first_no, w.nos,
           coalesce(nullif(m.alias, ''), 'Inverter ' || d.sn) as inverter
      from due d left join whole w on w.plant_id = d.plant_id and w.sn = d.sn
      left join private.meta m on m.sn = d.sn
     order by d.plant_id, m.ord nulls last, d.sn, d.no
  loop
    if r.first_no is null or r.first_no = r.no then
      -- strings left pointing here by an older email are free of it now
      update private.string_alert_state set group_no = null
       where plant_id = r.plant_id and sn = r.sn and group_no = r.no and no <> r.no and not dead;
    end if;
    update private.string_alert_state set dead = true, dead_since = r.since, sent_at = now(), n = 1, clear_at = null,
                                          group_no = r.first_no
     where plant_id = r.plant_id and sn = r.sn and no = r.no;
    if r.first_no is null or r.first_no = r.no then
      perform private.email_enqueue_plant(r.plant_id, 'string_dead',
        'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.since || ':1',
        jsonb_build_object('string', private.string_names(coalesce(r.nos, array[r.no])), 'inverter', r.inverter, 'since', r.since));
    end if;
  end loop;
  -- Dead strings with voltage for 15 min: one "back" each. It goes on a minute with
  -- voltage, so one stray sample before nightfall cannot send it overnight. A string
  -- that went in another string's email comes back quietly; the one that held the
  -- email waits for all of them, then names every one (0231).
  for r in
    select a.plant_id, a.sn, a.no, a.dead_since, a.clear_at, a.group_no,
           (select array_agg(g.no order by g.no) from private.string_alert_state g
             where g.plant_id = a.plant_id and g.sn = a.sn and g.group_no = a.no) as nos,
           coalesce(nullif(m.alias, ''), 'Inverter ' || a.sn) as inverter
      from private.string_alert_state a left join private.meta m on m.sn = a.sn
     where a.plant_id = any (todo) and a.dead and p_ts - a.clear_at >= 900 and a.last_alive = p_ts
       -- an email's holder waits until every string in it is back (0231)
       and not exists (select 1 from private.string_alert_state g
                        where g.plant_id = a.plant_id and g.sn = a.sn and g.group_no = a.no and g.no <> a.no and g.dead
                          and not (p_ts - g.clear_at >= 900 and g.last_alive = p_ts))
     order by a.plant_id, m.ord nulls last, a.sn, a.no
  loop
    -- a string that went in another's email keeps group_no while that one is still
    -- off, so its "back" names this string too
    update private.string_alert_state a
       set dead = false, dead_n = 0, clear_at = null,
           group_no = case when a.group_no <> a.no and exists (
                             select 1 from private.string_alert_state h
                              where h.plant_id = a.plant_id and h.sn = a.sn and h.no = a.group_no and h.dead)
                           then a.group_no end
     where a.plant_id = r.plant_id and a.sn = r.sn and a.no = r.no;
    if r.group_no is null or r.group_no = r.no then
      update private.string_alert_state set group_no = null
       where plant_id = r.plant_id and sn = r.sn and group_no = r.no and not dead;
      perform private.email_enqueue_plant(r.plant_id, 'string_back',
        'string_back:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.dead_since,
        jsonb_build_object('string', private.string_names(coalesce(r.nos, array[r.no])), 'inverter', r.inverter,
                           'since', r.dead_since, 'at', r.clear_at),
        'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.dead_since || ':1');
    end if;
  end loop;

  -- Each inverter's own newest reading (0119). One that was quiet gets its Readings
  -- back once it has reported for 15 min with no gap over 10 min (0151).
  for r in
    with d as (
      select x.plant_id, x.sn,
             max(extract(epoch from (x.device_time::timestamp at time zone plants.tz(c.plant_id)))::bigint) as dev
        from public.readings x join public.plant_config c on c.plant_id = x.plant_id
       where x.plant_id = any (todo) and x.ts = p_ts and x.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
       group by x.plant_id, x.sn
    )
    select d.plant_id, d.sn, d.dev, s.last_dev as prev, s.stale, s.stale_key, s.clear_at
      from d left join private.inverter_alert_state s on s.plant_id = d.plant_id and s.sn = d.sn
  loop
    if r.prev is null then
      insert into private.inverter_alert_state as s (plant_id, sn, last_dev) values (r.plant_id, r.sn, r.dev)
      on conflict (plant_id, sn) do update set last_dev = greatest(s.last_dev, excluded.last_dev);
    elsif r.dev > r.prev then
      clr := case when r.stale then case when r.clear_at is null or r.dev - r.prev > 600 then r.dev else r.clear_at end end;
      if r.stale and extract(epoch from now()) - r.dev <= 900 and r.dev - clr >= 900 then
        perform private.email_enqueue_plant(r.plant_id, 'logger_back', 'logger_back:' || substr(r.stale_key, 14),
          jsonb_build_object('since', split_part(r.stale_key, ':', 4)::bigint, 'at', clr,
                             'inverter', coalesce((select nullif(m.alias, '') from private.meta m where m.sn = r.sn), 'Inverter ' || r.sn)),
          r.stale_key);
        update private.inverter_alert_state set last_dev = r.dev, stale = false, stale_key = null, clear_at = null
         where plant_id = r.plant_id and sn = r.sn;
      else
        update private.inverter_alert_state set last_dev = r.dev, clear_at = clr where plant_id = r.plant_id and sn = r.sn;
      end if;
    end if;
  end loop;

  -- Everything else from one read of the minute's readings. Grid present is
  -- q_grid_present's rule (0055): over 100 V among the rows with the newest
  -- device_time; null when nobody reported a voltage.
  for r in
    with rd as (
      select x.plant_id, x.sn, x.device_time, x.grid_volt_v, x.batt_temp_c, x.batt_soc
        from public.readings x where x.plant_id = any (todo) and x.ts = p_ts
    ), newest as (
      select plant_id, max(device_time) as dt from rd where grid_volt_v is not null group by plant_id
    )
    select c.plant_id, jsonb_build_object(
             'present', case when count(rd.grid_volt_v) = 0 then null
                             else coalesce(bool_or(rd.grid_volt_v > 100) filter (
                                    where rd.grid_volt_v is not null and rd.device_time is not distinct from n.dt), false) end,
             'dev', max(case when rd.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
                             then extract(epoch from (rd.device_time::timestamp at time zone plants.tz(c.plant_id)))::bigint end),
             'temp', max(rd.batt_temp_c) filter (where rd.batt_temp_c > 0 and rd.batt_temp_c < 80),
             'spread', case when count(distinct rd.sn) filter (where rd.batt_soc between 1 and 100) >= 2
                            then max(rd.batt_soc) filter (where rd.batt_soc between 1 and 100)
                               - min(rd.batt_soc) filter (where rd.batt_soc between 1 and 100) end,
             'has_batt', coalesce(c.has_battery, true),
             'shared', coalesce(c.battery_banks = 'shared', false)) as f
      from public.plant_config c
      join rd on rd.plant_id = c.plant_id
      left join newest n on n.plant_id = c.plant_id
     where c.plant_id = any (todo)
     group by c.plant_id, c.has_battery, c.battery_banks
  loop
    begin
      perform private.email_plant_apply(r.plant_id, p_ts, r.f);
    exception when others then
      failed := failed || jsonb_build_object('plant', r.plant_id, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('plants', coalesce(array_length(todo, 1), 0), 'failed', failed);
end $function$;

CREATE OR REPLACE FUNCTION public.brand_tally(p_brand text, p_rows jsonb, p_shard integer, p_run_ms integer, p_plants integer)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  insert into plants.brand_calls as t (day, brand, kind, result, calls, ms_total, ms_max, plants, last_at)
  select (now() at time zone plants.market_tz())::date, x.brand, x.kind, x.result,
         sum(x.calls), sum(x.ms), max(x.ms_max), sum(x.plants), now()
    from (select coalesce(p_brand, '') as brand, r.kind, r.result, r.calls, r.ms, r.ms_max, 0::bigint as plants
            from jsonb_to_recordset(coalesce(p_rows, '[]')) as r(kind text, result text, calls bigint, ms bigint, ms_max int)
           where r.kind is not null and r.result is not null
          union all
          select '', 'poll_run', 's' || p_shard, 1, p_run_ms, p_run_ms, p_plants
           where p_shard is not null) x
   group by x.brand, x.kind, x.result
   order by x.brand, x.kind, x.result
  on conflict (day, brand, kind, result) do update set
    calls    = t.calls + excluded.calls,
    ms_total = t.ms_total + excluded.ms_total,
    ms_max   = greatest(t.ms_max, excluded.ms_max),
    plants   = t.plants + excluded.plants,
    last_at  = excluded.last_at;
$function$;

CREATE OR REPLACE FUNCTION public.brand_calls_report()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  d date := (now() at time zone plants.market_tz())::date - 1;
  out jsonb;
begin
  delete from plants.brand_calls where day < d - 400;
  if not exists (select 1 from plants.brand_calls where day = d) then return null; end if;

  with c as (select * from plants.brand_calls where day = d and kind <> 'poll_run'),
       r as (select * from plants.brand_calls where day = d and kind = 'poll_run'),
       tot as (
         select coalesce(sum(calls), 0) as calls,
                coalesce(sum(calls) filter (where result in ('429', '403_throttle', '5xx', 'network', 'timeout')), 0) as failed,
                coalesce(sum(ms_total), 0) as ms
           from c),
       pl as (select coalesce(sum(plants::numeric / nullif(calls, 0)), 0) as plants,
                     coalesce(sum(calls), 0) as runs,
                     coalesce(max(ms_max), 0) as slowest_ms
                from r)
  select jsonb_build_object(
           'day', d,
           'calls', tot.calls,
           'failed', tot.failed,
           'error_rate', round(tot.failed::numeric / nullif(tot.calls, 0), 4),
           'avg_call_ms', round(tot.ms::numeric / nullif(tot.calls, 0)),
           'plants', round(pl.plants, 1),
           'calls_per_plant', round(tot.calls / nullif(pl.plants, 0)),
           'poll_runs', pl.runs,
           'slowest_run_ms', pl.slowest_ms,
           'by_result', (select coalesce(jsonb_object_agg(result, n), '{}') from
                           (select result, sum(calls) as n from c group by result) x),
           'by_kind', (select coalesce(jsonb_object_agg(kind, n), '{}') from
                         (select kind, sum(calls) as n from c group by kind) y))
    into out
    from tot, pl;
  return out;
end $function$;

CREATE OR REPLACE FUNCTION public.job_check_inputs()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  d    date := (now() at time zone plants.market_tz())::date;
  m    private.job_check_mark;
  c    bigint; f bigint;
  jobs jsonb := '[]';
  fn_calls_state jsonb := '[]';
begin
  select x.calls, x.failed into c, f from plants.calls_on(d) x;
  select * into m from private.job_check_mark for update;
  insert into private.job_check_mark as t values (true, now(), d, c, f)
    on conflict (id) do update set at = excluded.at, day = excluded.day, calls = excluded.calls, failed = excluded.failed;

  if to_regclass('cron.job') is not null then
    with starts as (                                                     -- 0234
      select r.jobid, max(r.start_time) as last_start from cron.job_run_details r group by r.jobid
    ), ends as (                                                         -- 0234
      select distinct on (r.jobid) r.jobid, r.status, r.end_time, r.return_message
        from cron.job_run_details r
       where r.status in ('succeeded', 'failed')
       order by r.jobid, r.start_time desc
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'job', j.jobname, 'schedule', j.schedule, 'active', j.active,
             'last_start', s.last_start,                                 -- 0234
             'last_status', l.status,
             'last_end', l.end_time,
             'message', left(regexp_replace(coalesce(l.return_message, ''), '[^\s"''<>@]+@[^\s"''<>@]+\.[a-z]{2,}', '[email]', 'gi'), 200))
             order by j.jobname), '[]')
      into jobs
      from cron.job j
      left join starts s on s.jobid = j.jobid                            -- 0234
      left join ends l on l.jobid = j.jobid;                             -- 0234
  end if;

  delete from private.fn_calls where at < now() - interval '2 days';
  if to_regclass('net._http_response') is not null then
    fn_calls_state := private.fn_call_states();
  end if;

  return jsonb_build_object(
    'now', now(),
    'shards', (select coalesce(jsonb_agg(jsonb_build_object('shard', s.shard,
                 'last_at', plants.run_last_at(s.shard, d - 1))
                 order by s.shard), '[]')
                 from private.poll_shards() s),
    'jobs', jobs,
    'calls', fn_calls_state,
    'vendor', jsonb_build_object(
      'calls', case when m.day = d then c - m.calls else c end,
      'failed', case when m.day = d then f - m.failed else f end,
      'since', m.at),
    'email', (select jsonb_build_object('waiting', count(*), 'oldest_due', min(due_at))
                from public.email_queue where status = 'queued' and due_at <= now() - interval '10 minutes'),
    'checks', (select coalesce(jsonb_object_agg(name, jsonb_build_object('failing', failing, 'since', since)), '{}')
                 from private.job_checks));
end $function$;

revoke all on function public.brand_tally(text, jsonb, integer, integer, integer) from public, anon, authenticated;
grant execute on function public.brand_tally(text, jsonb, integer, integer, integer) to service_role;
revoke all on function public.brand_calls_report() from public, anon, authenticated;
grant execute on function public.brand_calls_report() to service_role;
drop function public.sunsynk_tally(jsonb, integer, integer, integer);
drop function public.sunsynk_calls_report();
drop table private.email_system_state;

-- ---------------------------------------------------------------------------
-- SOLAR-681 R18: the every-minute reader reads and saves, nothing else. Its side jobs run on
-- their own: alerts and plant checks here in SQL, the plant sync and today's temperatures as
-- their own calls of the poll function (task sync, task temps; private.schedule_jobs).

alter table plants.brands add column batt_positive_means text not null default 'discharging'
  check (batt_positive_means in ('charging', 'discharging'));

-- the reader's outcome for each login this minute, whether it saved or not (R18): the alert
-- sweep tells the brand's outage from ours by these
create or replace function public.login_outcomes(p_outcomes jsonb) returns void
  language sql security definer set search_path to '' as $$
  update plants.logins a set last_try_at = now(), last_try = o.outcome
    from jsonb_to_recordset(coalesce(p_outcomes, '[]'::jsonb)) as o(account uuid, outcome text)
   where a.id = o.account and o.outcome in ('ok', 'vendor', 'ours')
$$;
revoke all on function public.login_outcomes(jsonb) from public, anon, authenticated;
grant execute on function public.login_outcomes(jsonb) to service_role;

-- Alerts for each minute the reader has saved, in order. The cursor moves only past a minute
-- whose step ran, so a failed run is caught up by the next (at most 10 minutes back).
create or replace function private.alerts_minute() returns jsonb
  language plpgsql security definer set search_path to '' as $$
declare
  last_done bigint := (select c.value::bigint from public.app_config c where c.key = 'ALERTS_DONE_TS');
  -- two minutes back: every read of that minute has saved or given up by then (50 s deadline)
  upto bigint := (floor(extract(epoch from now()) / 60) * 60)::bigint - 120;
  m bigint;
  n int := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('private.alerts_minute')) then return jsonb_build_object('busy', true); end if;
  m := greatest(coalesce(last_done, upto - 60), upto - 600) + 60;
  while m <= upto loop
    perform public.email_poll_step(m, '[]'::jsonb, array(select distinct a.plant_id from public.agg_minute a where a.ts = m order by 1));
    insert into public.app_config (key, value, note) values ('ALERTS_DONE_TS', m, 'the last minute the alert step ran for (private.alerts_minute)')
    on conflict (key) do update set value = excluded.value;
    n := n + 1;
    m := m + 60;
  end loop;
  return jsonb_build_object('minutes', n, 'upto', upto);
end $$;
revoke all on function private.alerts_minute() from public, anon, authenticated;

-- Battery present, grid present, one bank or one per inverter, which way the battery sign
-- runs: each read plant once in ten minutes, on its own minute (was on the reader's list
-- minute). Database only.
create or replace function private.plant_checks() returns jsonb
  language plpgsql security definer set search_path to '' as $$
declare
  p bigint;
  n int := 0;
  sign text;
begin
  for p in select x from public.live_plants() x
            where x % 10 = (floor(extract(epoch from now()) / 60))::bigint % 10 order by x loop
    begin perform public.plant_features_detect(p); exception when others then raise warning 'plant_features_detect %: %', p, sqlerrm; end;
    begin perform public.battery_banks_detect(p); exception when others then raise warning 'battery_banks_detect %: %', p, sqlerrm; end;
    if (select c.batt_positive_means from public.plant_config c where c.plant_id = p) is null then
      sign := (select b.batt_positive_means from plants.brands b where b.code = plants.brand_of(p));
      begin perform public.batt_sign_detect(p, coalesce(sign, 'discharging')); exception when others then raise warning 'batt_sign_detect %: %', p, sqlerrm; end;
    end if;
    n := n + 1;
  end loop;
  return jsonb_build_object('plants', n);
end $$;
revoke all on function private.plant_checks() from public, anon, authenticated;
CREATE OR REPLACE FUNCTION private.schedule_jobs()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'pg_temp'
AS $function$
declare j record;
begin
  -- pg_cron keys a job by name and user: run as anyone else, every job would be made twice
  if current_user <> 'postgres' then
    raise exception 'run private.schedule_jobs() as postgres, not %', current_user using errcode = '42501';
  end if;
  for j in select * from (values
    ('agg-minute-rollup',    '40 4 * * *',         $c$select private.agg_minute_rollup(31)$c$),
    ('alerts',               '* * * * *',          $c$select private.alerts_minute()$c$),
    ('plant-check',          '* * * * *',          $c$select private.plant_checks()$c$),
    ('plant-sync',           '* * * * *',          $c$select private.call_fn('poll', '{"task":"sync"}', 55000)$c$),
    ('temps',                '* * * * *',          $c$select private.call_fn('poll', '{"task":"temps"}', 55000)$c$),
    ('billing-delete',       '*/5 * * * *',        $c$select billing.delete_due()$c$),
    ('billing-history',      '* * * * *',          $c$select private.call_fn('recover?queue=1', '{}', 60000)$c$),
    ('billing-run',          '*/5 4-5 * * *',      $c$select private.call_fn('billing/run', '{}', 120000)$c$),
    ('ensure-partitions',    '0 3 * * *',          $c$select private.ensure_partitions()$c$),
    ('first-load-continue',  '*/2 * * * *',        $c$select private.first_load_continue()$c$),
    ('grid-off',             '10 4 * * *',         $c$select private.grid_off_update_all()$c$),
    ('history-delete',       '* * * * *',          $c$call private.history_delete_run()$c$),
    ('history-delete-slow',  '*/15 * * * *',       $c$call private.history_delete_check()$c$),
    ('job-check',            '2-59/5 * * * *',     $c$select private.call_fn('job-check', '{}', 30000)$c$),
    ('notify-email',         '* * * * *',          $c$select private.call_fn('notify-email', '{}', 55000)$c$),
    ('notify-push',          '* * * * *',          $c$select private.call_fn('notify-push', '{}', 55000)$c$),
    ('purge-cron-log',       '45 4 * * *',         $c$delete from cron.job_run_details where end_time < now() - make_interval(days => 7)$c$),
    ('rollup-old-days',      '*/5 5-7 * * *',      $c$call private.rollup_old_days(31)$c$),
    ('sunsynk-plant-energy', '15 2 * * *',         $c$select private.call_fn('sync-plant-energy', '{}', 150000)$c$),
    ('sunsynk-poll',         '* * * * *',          $c$select private.call_fn('poll', jsonb_build_object('shard', s.shard, 'shards', s.shards, 'delay_ms', s.delay_ms), 55000) from private.poll_shards() s$c$),
    ('sunsynk-recover',      '5 4,10,16,22 * * *', $c$select private.call_fn('recover', '{}', 150000)$c$)
  ) t(name, sched, cmd) loop
    perform cron.schedule(j.name, j.sched, j.cmd);   -- by name: an existing job is updated in place
  end loop;
end $function$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform private.schedule_jobs();   -- the four new jobs (R18)
  end if;
end $$;

-- every door the reader and the links use: the server only (functions dropped and made again
-- in this migration start with no grants of their own)
revoke all on function public.poll_jobs_v2(integer, integer, uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.poll_jobs_v2(integer, integer, uuid, timestamptz) to service_role;
revoke all on function public.share_claim_any(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.share_claim_any(uuid, uuid, text, text) to service_role;

-- the reader's save and the account delete write logins through these (R1)
-- a read login's token: the newer one wins (0250), and it was read just now
create or replace function plants.tokens_saved(p_tokens jsonb) returns void
  language sql security definer set search_path to '' as $$
  update plants.logins sa
     set access_token = case when (t->>'expires')::bigint >= coalesce(sa.access_expires_at, 0) then t->>'access' else sa.access_token end,
         access_expires_at = greatest((t->>'expires')::bigint, coalesce(sa.access_expires_at, 0)),
         last_ok_at = now(), last_error = null
    from jsonb_array_elements(coalesce(p_tokens, '[]'::jsonb)) t
   where sa.id = (t->>'account')::uuid
$$;
-- the other logins that see these plants were served this minute too (a row another write holds is left)
create or replace function plants.logins_served(p_plants bigint[], p_except uuid[]) returns void
  language sql security definer set search_path to '' as $$
  update plants.logins s set last_ok_at = now()
   where s.id in (select o.id from plants.logins o
                   where o.status = 'ok' and o.id <> all (coalesce(p_except, '{}'))
                     and exists (select 1 from plants.login_plants lp where lp.login = o.id and lp.plant = any (coalesce(p_plants, '{}')))
                   order by o.id for no key update skip locked)
$$;
-- every login of a user whose account goes
create or replace function plants.user_logins_delete(p_user uuid) returns void
  language sql security definer set search_path to '' as $$
  delete from plants.logins where user_id = p_user
$$;
revoke all on function plants.tokens_saved(jsonb), plants.logins_served(bigint[], uuid[]), plants.user_logins_delete(uuid)
  from public, anon, authenticated;

-- R21: shards start 0, 2 or 4 s past the minute
CREATE OR REPLACE FUNCTION private.poll_shards(p_per_shard integer DEFAULT 10)
 RETURNS TABLE(shard integer, shards integer, delay_ms integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_temp'
AS $function$
  with n as (
    select greatest(1, ceil(count(*)::numeric / greatest(p_per_shard, 1)))::int as shards
      from plants.logins
     where status = 'ok'
  )
  -- 0, 2 or 4 s past the minute (SOLAR-681 R21): spread enough for the start, and every
  -- reading saved before its page asks at 12-42 s (it was 0/10/20 s)
  select s.i, n.shards, (s.i % 3) * 2000
    from n, generate_series(0, n.shards - 1) as s(i)
$function$;

-- ---------------------------------------------------------------------------
-- SOLAR-681 R23: a plant figure worked out in two places gets one function; app and mail
-- both call it.

-- Independence: the share of the home's use not bought from the grid, 0-100, not rounded
-- (the app rounds to whole %, mail to its own format). Was _energy_row's selfSuff and notify's
-- independence().
create or replace function public.independence_pct(p_home double precision, p_import double precision)
  returns double precision language sql immutable set search_path to '' as $$
  select case when coalesce(p_home, 0) > 0
              then greatest(0, least(100, ((p_home - coalesce(p_import, 0)) / p_home) * 100)) else 0 end
$$;

-- A span's totals, from the one day-energy function: made, home, bought, independence.
create or replace function public.span_figures(p_plant bigint, p_from date, p_to date)
  returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object(
           'made_kwh', coalesce(sum(e.pv_kwh), 0), 'home_kwh', coalesce(sum(e.load_kwh), 0),
           'import_kwh', coalesce(sum(e.imp_kwh), 0),
           'independence_pct', public.independence_pct(coalesce(sum(e.load_kwh), 0), coalesce(sum(e.imp_kwh), 0)))
    from public._plant_day_energy(p_plant, p_from, p_to) e
   -- a day of zeros is the brand's filler for a day with no readings (notify hasData)
   where coalesce(e.load_kwh, 0) > 0 or coalesce(e.pv_kwh, 0) > 0
$$;
revoke all on function public.span_figures(bigint, date, date) from public, anon, authenticated;
grant execute on function public.span_figures(bigint, date, date) to service_role;

-- Battery % at an instant: the newest minute with a charge in the 10 minutes up to it. Was
-- email_plant_events' chargePct and notify's socAt().
create or replace function public.soc_at(p_plant bigint, p_at bigint)
  returns integer language sql stable security definer set search_path to '' as $$
  select round(a.soc)::int from public.agg_minute a
   where a.plant_id = p_plant and a.ts between p_at - 600 and p_at and a.soc is not null
   order by a.ts desc limit 1
$$;
revoke all on function public.soc_at(bigint, bigint) from public, anon, authenticated;
grant execute on function public.soc_at(bigint, bigint) to service_role;

-- ---------------------------------------------------------------------------
-- SOLAR-681 R13, R14: the fake tester plants (SOLAR-270, logins ending @mock) are brand `mock`,
-- with our own ids from plants.plant_id_seq and their serials as mock:<serial>: the first live use
-- of our own plant ids, and a brand whose ids can never meet SunSynk's.

update plants.logins set brand = 'mock' where kind = 'login' and lower(username) like '%@mock';

do $$
declare
  p record;
  n bigint;
  tc record;
  moved int := 0;
  serials text[];
begin
  for p in
    select pl.* from plants.plants pl
     where pl.brand = 'sunsynk'
       and exists (select 1 from plants.login_plants lp join plants.logins l on l.id = lp.login where lp.plant = pl.id and l.brand = 'mock')
       and not exists (select 1 from plants.login_plants lp join plants.logins l on l.id = lp.login where lp.plant = pl.id and l.brand <> 'mock')
       and not exists (select 1 from plants.claims c where c.plant = pl.id)
     order by pl.id
  loop
    n := nextval('plants.plant_id_seq');
    insert into plants.plants (id, brand, vendor_id, time_zone, version, legacy, created_at)
    values (n, 'mock', p.vendor_id, p.time_zone, p.version + 1, false, p.created_at);
    -- plant_config is a parent too (alert state, refill queue): a copy under the new id first
    insert into public.plant_config
    select (jsonb_populate_record(null::public.plant_config, to_jsonb(c) || jsonb_build_object('plant_id', n))).*
      from public.plant_config c where c.plant_id = p.id;
    -- every table that keys on a plant: its rows move to the new id (partitioned tables by their parent)
    for tc in
      select cl.relnamespace::regnamespace::text as sch, cl.relname as tab, a.attname as col
        from pg_attribute a join pg_class cl on cl.oid = a.attrelid
       where a.attname in ('plant_id', 'plant') and a.atttypid = 'bigint'::regtype and not a.attisdropped
         and cl.relkind in ('r', 'p') and not cl.relispartition
         and cl.relnamespace::regnamespace::text in ('public', 'private', 'billing', 'msg', 'plants')
         and not (cl.relnamespace::regnamespace::text = 'plants' and cl.relname = 'plants')
         and not (cl.relnamespace::regnamespace::text = 'public' and cl.relname = 'plant_config')
    loop
      execute format('update %I.%I set %I = $1 where %I = $2', tc.sch, tc.tab, tc.col, tc.col) using n, p.id;
    end loop;
    update public.app_config set value = n where key = 'CALIBRATION_PLANT' and value = p.id;
    update billing.invoices set plants = array_replace(plants, p.id, n) where p.id = any (plants);
    update billing.outbox set ref = n::text where ref = p.id::text;
    delete from public.plant_config where plant_id = p.id;
    delete from plants.plants where id = p.id;
    moved := moved + 1;
  end loop;

  -- their inverters: mock:<serial>, wherever a mock plant's row holds one (by plant where the table
  -- has a plant, else by the serials those plants ever had)
  serials := array(select distinct x.sn from (
      select i.sn from private.inverters i join plants.plants pl on pl.id = i.plant_id where pl.brand = 'mock'
      union select m.sn from private.meta m join plants.plants pl on pl.id = m.plant_id where pl.brand = 'mock'
      union select r.sn from public.readings r join plants.plants pl on pl.id = r.plant_id where pl.brand = 'mock') x
     where x.sn not like 'mock:%');
  if cardinality(serials) > 0 then
    if exists (select 1 from private.inverters i join plants.plants pl on pl.id = i.plant_id
                where pl.brand <> 'mock' and i.sn = any (serials)) then
      raise exception 'R14: a real inverter has a fake plant''s serial';
    end if;
    for tc in
      select cl.relnamespace::regnamespace::text as sch, cl.relname as tab,
             exists (select 1 from pg_attribute b where b.attrelid = cl.oid and b.attname = 'plant_id' and not b.attisdropped) as by_plant
        from pg_attribute a join pg_class cl on cl.oid = a.attrelid
       where a.attname = 'sn' and a.atttypid = 'text'::regtype and not a.attisdropped
         and cl.relkind in ('r', 'p') and not cl.relispartition
         and cl.relnamespace::regnamespace::text in ('public', 'private', 'billing', 'msg', 'plants')
    loop
      if tc.by_plant then
        execute format('update %I.%I set sn = ''mock:'' || sn where sn = any ($1) and plant_id in (select id from plants.plants where brand = ''mock'')', tc.sch, tc.tab) using serials;
      else
        execute format('update %I.%I set sn = ''mock:'' || sn where sn = any ($1)', tc.sch, tc.tab) using serials;
      end if;
    end loop;
  end if;
  raise notice 'R14: % fake plants moved to brand mock, % serials prefixed', moved, coalesce(cardinality(serials), 0);
  if exists (select 1 from plants.plants pl where pl.brand = 'mock' and pl.id < 1000000000000) then
    raise exception 'R14: a mock plant kept an old id';
  end if;
end $$;

-- R16: returned columns by the login's own word (were sunsynk_username)
drop function public.api_logins();
drop function public.share_account_get();
CREATE OR REPLACE FUNCTION public.api_logins()
 RETURNS TABLE(account_id uuid, username text, status text, linked_at timestamp with time zone, last_ok_at timestamp with time zone, plants jsonb, kind text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with me as (select auth.uid() u, (select id from billing.accounts where user_id = auth.uid()) acc)
  select a.id, a.username, a.status,
         case when a.kind = 'share' then (select min(x.linked_at) from plants.user_plants x where x.account_id = a.id and x.user_id = me.u)
              else a.linked_at end,
         a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name,
                     'paused', not exists (select 1 from billing.seats se where se.account = me.acc and se.plant = pu.plant_id
                                              and se.closed_at is null),
                     'linked_at', pu.linked_at,
                     'inverters', (select count(*) from private.inverters i where i.plant_id = pu.plant_id),
                     'share_gone', pu.share_gone_at is not null,
                     'started_at', (select s.started_at from private.plant_alert_state s where s.plant_id = pu.plant_id))
                   order by pu.linked_at, pu.plant_id)
                     from plants.user_plants pu where pu.account_id = a.id and pu.user_id = me.u), '[]'::jsonb),
         a.kind
    from plants.logins a cross join me
   where a.user_id = me.u
      or (a.kind = 'share' and exists (select 1 from plants.user_plants x where x.account_id = a.id and x.user_id = me.u))
   order by 4 desc
$function$;

CREATE OR REPLACE FUNCTION public.share_account_get()
 RETURNS TABLE(id uuid, user_id uuid, username text, access_token text, access_expires_at bigint, status text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  select a.id, a.user_id, a.username, a.access_token, a.access_expires_at, a.status
    from plants.logins a where a.kind = 'share'
$function$;

CREATE OR REPLACE FUNCTION private.refresh_store(p_account uuid, p_refresh text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'vault', 'pg_temp'
AS $function$
declare
  old_id uuid;
  new_id uuid;
begin
  -- Vault secret names are unique, so the old one must go before the new one is
  -- created under the same name. Same transaction: there is never a moment with
  -- no secret on file.
  select refresh_secret_id into old_id from plants.logins where id = p_account;
  if old_id is not null then
    update plants.logins set refresh_secret_id = null where id = p_account;
    delete from vault.secrets where id = old_id;
  end if;
  new_id := vault.create_secret(p_refresh, 'brand_refresh_' || p_account::text,
                                'brand refresh token for login ' || p_account::text);
  update plants.logins set refresh_secret_id = new_id where id = p_account;
end $function$;

CREATE OR REPLACE FUNCTION private.schedule_jobs()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'pg_temp'
AS $function$
declare j record;
begin
  -- pg_cron keys a job by name and user: run as anyone else, every job would be made twice
  if current_user <> 'postgres' then
    raise exception 'run private.schedule_jobs() as postgres, not %', current_user using errcode = '42501';
  end if;
  for j in select * from (values
    ('agg-minute-rollup',    '40 4 * * *',         $c$select private.agg_minute_rollup(31)$c$),
    ('alerts',               '* * * * *',          $c$select private.alerts_minute()$c$),
    ('plant-check',          '* * * * *',          $c$select private.plant_checks()$c$),
    ('plant-sync',           '* * * * *',          $c$select private.call_fn('poll', '{"task":"sync"}', 55000)$c$),
    ('temps',                '* * * * *',          $c$select private.call_fn('poll', '{"task":"temps"}', 55000)$c$),
    ('billing-delete',       '*/5 * * * *',        $c$select billing.delete_due()$c$),
    ('billing-history',      '* * * * *',          $c$select private.call_fn('recover?queue=1', '{}', 60000)$c$),
    ('billing-run',          '*/5 4-5 * * *',      $c$select private.call_fn('billing/run', '{}', 120000)$c$),
    ('ensure-partitions',    '0 3 * * *',          $c$select private.ensure_partitions()$c$),
    ('first-load-continue',  '*/2 * * * *',        $c$select private.first_load_continue()$c$),
    ('grid-off',             '10 4 * * *',         $c$select private.grid_off_update_all()$c$),
    ('history-delete',       '* * * * *',          $c$call private.history_delete_run()$c$),
    ('history-delete-slow',  '*/15 * * * *',       $c$call private.history_delete_check()$c$),
    ('job-check',            '2-59/5 * * * *',     $c$select private.call_fn('job-check', '{}', 30000)$c$),
    ('notify-email',         '* * * * *',          $c$select private.call_fn('notify-email', '{}', 55000)$c$),
    ('notify-push',          '* * * * *',          $c$select private.call_fn('notify-push', '{}', 55000)$c$),
    ('purge-cron-log',       '45 4 * * *',         $c$delete from cron.job_run_details where end_time < now() - make_interval(days => 7)$c$),
    ('rollup-old-days',      '*/5 5-7 * * *',      $c$call private.rollup_old_days(31)$c$),
    ('plant-energy',         '15 2 * * *',         $c$select private.call_fn('sync-plant-energy', '{}', 150000)$c$),
    ('reader',               '* * * * *',          $c$select private.call_fn('poll', jsonb_build_object('shard', s.shard, 'shards', s.shards, 'delay_ms', s.delay_ms), 55000) from private.poll_shards() s$c$),
    ('recover',              '5 4,10,16,22 * * *', $c$select private.call_fn('recover', '{}', 150000)$c$)
  ) t(name, sched, cmd) loop
    perform cron.schedule(j.name, j.sched, j.cmd);   -- by name: an existing job is updated in place
  end loop;
  -- the names before SOLAR-681 R16: gone, so no job runs twice
  perform cron.unschedule(jobname) from cron.job where jobname in ('sunsynk-poll', 'sunsynk-recover', 'sunsynk-plant-energy');
end $function$;

revoke all on function public.api_logins() from public, anon;
grant execute on function public.api_logins() to authenticated, service_role;
revoke all on function public.share_account_get() from public, anon, authenticated;
grant execute on function public.share_account_get() to service_role;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then perform private.schedule_jobs(); end if;
end $$;

-- every working login, for the plant-sync job (R18): a login whose plants are all paused or read
-- through another login still finds a plant added at the brand
create or replace function public.sync_logins() returns table (id uuid, user_id uuid, username text, brand text,
    access_token text, access_expires_at bigint)
  language sql stable security definer set search_path to '' as $$
  select l.id, l.user_id, l.username, l.brand, l.access_token, l.access_expires_at
    from plants.logins l where l.status = 'ok' order by l.id
$$;
revoke all on function public.sync_logins() from public, anon, authenticated;
grant execute on function public.sync_logins() to service_role;

CREATE OR REPLACE FUNCTION private.call_fn(p_path text, p_body jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 55000)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare rid bigint;
begin
  rid := net.http_post(
    url := private.functions_url() || '/' || p_path,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
      'Content-Type', 'application/json'),
    body := p_body,
    timeout_milliseconds := p_timeout_ms);
  insert into private.fn_calls (id, fn, shard, timeout_ms)
  values (rid, split_part(split_part(p_path, '?', 1), '/', 1) || coalesce(':' || (p_body ->> 'task'), ''), (p_body ->> 'shard')::int, p_timeout_ms)
  on conflict (id) do nothing;
  return rid;
end $function$;


-- ---------------------------------------------------------------------------
-- the latest bodies of the functions the parts above made again

CREATE OR REPLACE FUNCTION public.email_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  now_s bigint := extract(epoch from now())::bigint;
  b plants.brand_state;
  tried int;
  failing int;
  t_all int := 0;
  f_all int := 0;
  down boolean;
  r record;
  n_stale int := 0;
  n_rep int := 0;
begin
  -- Each brand's cloud on its own (R17): one brand's outage never mutes another's alerts. A
  -- login counts when poll tried it in the last 10 minutes; it is failing when its last try
  -- was the brand's fault and nothing good came for 10 min. Down: over half failing, and at
  -- least 3 of them, or all of them when fewer than 3 were tried (0119). Back once not down
  -- for 15 min (0151). Outage ids come from one sequence, so mail keys never meet across brands.
  for b in select * from plants.brand_state order by brand for update loop
    select count(*) filter (where a.last_try_at > now() - interval '10 minutes'),
           count(*) filter (where a.last_try_at > now() - interval '3 minutes' and a.last_try = 'vendor'
                              and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes')
      into tried, failing
      from plants.login_info a where a.status = 'ok' and a.brand = b.brand;
    t_all := t_all + tried; f_all := f_all + failing;
    down := failing >= least(3, tried) and failing > 0 and failing * 2 > tried;

    if down and not b.down then
      b.down := true; b.outage_id := nextval('plants.outage_id_seq'); b.clear_since := null;
      b.down_since := (select extract(epoch from min(coalesce(a.last_ok_at, a.linked_at)))::bigint
                         from plants.login_info a
                        where a.status = 'ok' and a.brand = b.brand and a.last_try = 'vendor'
                          and a.last_try_at > now() - interval '3 minutes'
                          and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes');
    elsif down then
      b.clear_since := null;
    elsif b.down then
      b.clear_since := coalesce(b.clear_since, now());
      if b.clear_since <= now() - interval '15 minutes' then
        -- Back: everyone told it was down hears it is back.
        insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
        select q.user_id, q.plant_id, 'sunsynk_back', 'sunsynk_back:' || b.outage_id, q.key,
               jsonb_build_object('since', b.down_since, 'at', extract(epoch from b.clear_since)::bigint), 0
          from public.email_queue q
         where q.key = 'sunsynk_down:' || b.outage_id
        on conflict do nothing;
        b.down := false; b.up_at := now(); b.clear_since := null;
      end if;
    end if;
    if b.down then
      -- Users on a failing login; one email each, about their first plant on it.
      -- Run every minute of the outage, so a login that fails later is told too.
      insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
      select distinct on (pu.user_id) pu.user_id, pu.plant_id, 'sunsynk_down', 'sunsynk_down:' || b.outage_id,
             jsonb_build_object('since', b.down_since), 0
        from plants.login_info a join plants.user_plants pu on pu.account_id = a.id
       where a.status = 'ok' and a.brand = b.brand and a.last_try = 'vendor' and a.last_try_at > now() - interval '3 minutes'
         and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes'
         and private.plant_live(pu.user_id, pu.plant_id)                          -- 0256
       order by pu.user_id, pu.linked_at
      on conflict do nothing;
    end if;
    update plants.brand_state set down = b.down, outage_id = b.outage_id, down_since = b.down_since,
           up_at = b.up_at, clear_since = b.clear_since
     where brand = b.brand;
  end loop;

  -- No readings: 30 min since the brand's newest reading for the plant, while poll
  -- still tries a login on it (ours not running is not the inverter going quiet),
  -- and not during an outage of the plant's brand (that has its own email) nor in the
  -- 15 min after one, while readings that the outage held up come back. A plant started
  -- again gets 30 min from the start, as a new link does (0174).
  begin
    for r in
      select s.plant_id, s.last_dev from private.plant_alert_state s
       where not s.stale and s.last_dev < now_s - 1800 and not coalesce(s.started_at between now_s - 1800 and now_s, false)   -- 0174
         and exists (select 1 from plants.brand_state bs
                      where bs.brand = plants.brand_of(s.plant_id) and not bs.down and (bs.up_at is null or bs.up_at < now() - interval '15 minutes'))
         and exists (select 1 from plants.user_plants pu join plants.login_info a on a.id = pu.account_id
                      where pu.plant_id = s.plant_id and a.status = 'ok' and a.last_try in ('ok', 'vendor')
                        and a.last_try_at > now() - interval '3 minutes')
       for update of s skip locked
    loop
      update private.plant_alert_state set stale = true, stale_key = 'logger_stale:' || r.plant_id || ':' || r.last_dev,
             stale_clear_at = null
       where plant_id = r.plant_id;
      perform private.email_enqueue_plant(r.plant_id, 'logger_stale', 'logger_stale:' || r.plant_id || ':' || r.last_dev,
        jsonb_build_object('since', r.last_dev));
      n_stale := n_stale + 1;
    end loop;
    -- One inverter quiet for 30 min while another on the plant still reports (0119).
    -- An inverter no longer on the plant is left alone.
    for r in
      select i.plant_id, i.sn, i.last_dev, coalesce(nullif(m.alias, ''), 'Inverter ' || i.sn) as inverter
        from private.inverter_alert_state i
        join private.plant_alert_state s on s.plant_id = i.plant_id
        left join plants.meta_info m on m.sn = i.sn
       where not i.stale and i.last_dev < now_s - 1800 and not coalesce(s.started_at between now_s - 1800 and now_s, false)   -- 0174
         and not s.stale and s.last_dev >= now_s - 900
         and exists (select 1 from plants.inverter_info v where v.sn = i.sn and v.plant_id = i.plant_id)
         and exists (select 1 from plants.brand_state bs
                      where bs.brand = plants.brand_of(i.plant_id) and not bs.down and (bs.up_at is null or bs.up_at < now() - interval '15 minutes'))
         and exists (select 1 from plants.user_plants pu join plants.login_info a on a.id = pu.account_id
                      where pu.plant_id = i.plant_id and a.status = 'ok' and a.last_try in ('ok', 'vendor')
                        and a.last_try_at > now() - interval '3 minutes')
       for update of i skip locked
    loop
      update private.inverter_alert_state set stale = true, stale_key = 'logger_stale:' || r.plant_id || ':' || r.sn || ':' || r.last_dev,
             clear_at = null
       where plant_id = r.plant_id and sn = r.sn;
      perform private.email_enqueue_plant(r.plant_id, 'logger_stale', 'logger_stale:' || r.plant_id || ':' || r.sn || ':' || r.last_dev,
        jsonb_build_object('since', r.last_dev, 'inverter', r.inverter));
      n_stale := n_stale + 1;
    end loop;
  end;

  -- No once-a-day repeat while battery hot, uneven charge or panels stopped last: each
  -- has its "back" note now (0151).

  -- Reports from 07:00 local: weekly on Monday, monthly on the 1st, yearly on 1 January,
  -- for plants linked by the first day of the period they cover (private.reports_due).
  with ins as (
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    select user_id, plant_id, 'report_' || period, 'report_' || period || ':' || plant_id || ':' || d,
           jsonb_build_object('today', d), 2
      from private.reports_due(now())
    on conflict do nothing
    returning 1
  )
  select count(*) into n_rep from ins;

  return jsonb_build_object('down', (select coalesce(jsonb_agg(x.brand order by x.brand), '[]') from plants.brand_state x where x.down),
                            'tried', t_all, 'failing', f_all,
                            'stale', n_stale, 'reports', n_rep);
end $function$;

CREATE OR REPLACE FUNCTION public.email_poll_step(p_ts bigint, p_outcomes jsonb, p_plants bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  todo bigint[];
  r record;
  clr bigint;
  failed jsonb := '[]'::jsonb;
begin
  perform public.login_outcomes(p_outcomes);   -- the reader records outcomes itself now (R18)

  -- Plants with config (purged ones have none) not already stepped for this minute.
  -- The rows stay locked to the end, so a link kick polling the same account in the
  -- same minute waits here and then finds them stepped: strings are counted once.
  insert into private.plant_alert_state (plant_id)
  select c.plant_id from plants.settings c where c.plant_id = any (coalesce(p_plants, '{}')) order by 1
  on conflict do nothing;
  select coalesce(array_agg(x.plant_id), '{}') into todo
    from (select s.plant_id from private.plant_alert_state s
           where s.plant_id = any (coalesce(p_plants, '{}')) and (s.stepped_ts is null or s.stepped_ts < p_ts)
           order by s.plant_id for update) x;

  -- Strings, all plants at once: a string with voltage is alive; one under 1.5 V and
  -- 5 W while another string on the plant makes over 200 W counts a dead sample, but
  -- only once the string itself has made over 200 W (an input with no panels never
  -- has; SOLAR-188). A string on another inverter counts only when both inverters
  -- reported in the last 10 min (poll carries an inverter's strings for 5 runs), so an
  -- inverter's only used string can stop and be seen (0231, SOLAR-613). A dead string
  -- stays dead until it has had voltage for 15 min with no dead sample (clear_at, 0151).
  insert into private.string_alert_state as st (plant_id, sn, no, last_alive, dead_n, made_power)
  with fresh as (
    select x.plant_id, x.sn
      from public.readings x join plants.settings c on c.plant_id = x.plant_id
     where x.plant_id = any (todo) and x.ts = p_ts and x.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
     group by x.plant_id, x.sn
    having max(extract(epoch from (x.device_time::timestamp at time zone plants.tz(c.plant_id)))::bigint) >= p_ts - 600
  )
  select x.plant_id, x.sn, x.no, case when x.alive then p_ts end, 0, x.made
    from (select s.plant_id, s.sn, s.no, coalesce(s.volt_v, 0) >= 1.5 as alive,
                 coalesce(s.power_w, 0) > 200 as made,
                 coalesce(s.volt_v, 0) < 1.5 and coalesce(s.power_w, 0) < 5
                   and exists (select 1 from public.strings o where o.plant_id = s.plant_id and o.ts = p_ts
                                  and (o.sn, o.no) <> (s.sn, s.no) and coalesce(o.power_w, 0) > 200
                                  and (o.sn = s.sn
                                       or (exists (select 1 from fresh f where f.plant_id = s.plant_id and f.sn = s.sn)
                                           and exists (select 1 from fresh f where f.plant_id = o.plant_id and f.sn = o.sn)))) as dead_in_sun
            from public.strings s
           where s.plant_id = any (todo) and s.ts = p_ts) x
   where x.alive or x.dead_in_sun
  on conflict (plant_id, sn, no) do update set
    last_alive = coalesce(excluded.last_alive, st.last_alive),
    made_power = st.made_power or excluded.made_power,
    dead_n     = case when excluded.last_alive is not null or not st.made_power then 0
                      when st.dead then st.dead_n else st.dead_n + 1 end,
    clear_at   = case when st.dead and excluded.last_alive is not null then coalesce(st.clear_at, excluded.last_alive) end;
  -- Strings dead in the sun for 12 samples: one email each. When every string that has
  -- made power on an inverter stops in the same minute, that is one email for the
  -- inverter ("Strings 1 and 2"), kept on its lowest string; the others are marked with
  -- group_no and come back without an email of their own (0231).
  for r in
    with due as (
      select a.plant_id, a.sn, a.no, coalesce(a.last_alive + 60, p_ts - 900) as since
        from private.string_alert_state a
       where a.plant_id = any (todo) and not a.dead and a.dead_n >= 12
    ), inv as (
      select d.plant_id, d.sn, min(d.no) as first_no, count(*) as n,
             array_agg(d.no order by d.no) as nos
        from due d group by d.plant_id, d.sn
    ), whole as (
      select i.* from inv i
       where i.n >= 2
         and i.n = (select count(*) from private.string_alert_state a
                     where a.plant_id = i.plant_id and a.sn = i.sn and a.made_power and not a.dead)
    )
    select d.plant_id, d.sn, d.no, d.since, w.first_no, w.nos,
           coalesce(nullif(m.alias, ''), 'Inverter ' || d.sn) as inverter
      from due d left join whole w on w.plant_id = d.plant_id and w.sn = d.sn
      left join plants.meta_info m on m.sn = d.sn
     order by d.plant_id, m.ord nulls last, d.sn, d.no
  loop
    if r.first_no is null or r.first_no = r.no then
      -- strings left pointing here by an older email are free of it now
      update private.string_alert_state set group_no = null
       where plant_id = r.plant_id and sn = r.sn and group_no = r.no and no <> r.no and not dead;
    end if;
    update private.string_alert_state set dead = true, dead_since = r.since, sent_at = now(), n = 1, clear_at = null,
                                          group_no = r.first_no
     where plant_id = r.plant_id and sn = r.sn and no = r.no;
    if r.first_no is null or r.first_no = r.no then
      perform private.email_enqueue_plant(r.plant_id, 'string_dead',
        'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.since || ':1',
        jsonb_build_object('string', private.string_names(coalesce(r.nos, array[r.no])), 'inverter', r.inverter, 'since', r.since));
    end if;
  end loop;
  -- Dead strings with voltage for 15 min: one "back" each. It goes on a minute with
  -- voltage, so one stray sample before nightfall cannot send it overnight. A string
  -- that went in another string's email comes back quietly; the one that held the
  -- email waits for all of them, then names every one (0231).
  for r in
    select a.plant_id, a.sn, a.no, a.dead_since, a.clear_at, a.group_no,
           (select array_agg(g.no order by g.no) from private.string_alert_state g
             where g.plant_id = a.plant_id and g.sn = a.sn and g.group_no = a.no) as nos,
           coalesce(nullif(m.alias, ''), 'Inverter ' || a.sn) as inverter
      from private.string_alert_state a left join plants.meta_info m on m.sn = a.sn
     where a.plant_id = any (todo) and a.dead and p_ts - a.clear_at >= 900 and a.last_alive = p_ts
       -- an email's holder waits until every string in it is back (0231)
       and not exists (select 1 from private.string_alert_state g
                        where g.plant_id = a.plant_id and g.sn = a.sn and g.group_no = a.no and g.no <> a.no and g.dead
                          and not (p_ts - g.clear_at >= 900 and g.last_alive = p_ts))
     order by a.plant_id, m.ord nulls last, a.sn, a.no
  loop
    -- a string that went in another's email keeps group_no while that one is still
    -- off, so its "back" names this string too
    update private.string_alert_state a
       set dead = false, dead_n = 0, clear_at = null,
           group_no = case when a.group_no <> a.no and exists (
                             select 1 from private.string_alert_state h
                              where h.plant_id = a.plant_id and h.sn = a.sn and h.no = a.group_no and h.dead)
                           then a.group_no end
     where a.plant_id = r.plant_id and a.sn = r.sn and a.no = r.no;
    if r.group_no is null or r.group_no = r.no then
      update private.string_alert_state set group_no = null
       where plant_id = r.plant_id and sn = r.sn and group_no = r.no and not dead;
      perform private.email_enqueue_plant(r.plant_id, 'string_back',
        'string_back:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.dead_since,
        jsonb_build_object('string', private.string_names(coalesce(r.nos, array[r.no])), 'inverter', r.inverter,
                           'since', r.dead_since, 'at', r.clear_at),
        'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.dead_since || ':1');
    end if;
  end loop;

  -- Each inverter's own newest reading (0119). One that was quiet gets its Readings
  -- back once it has reported for 15 min with no gap over 10 min (0151).
  for r in
    with d as (
      select x.plant_id, x.sn,
             max(extract(epoch from (x.device_time::timestamp at time zone plants.tz(c.plant_id)))::bigint) as dev
        from public.readings x join plants.settings c on c.plant_id = x.plant_id
       where x.plant_id = any (todo) and x.ts = p_ts and x.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
       group by x.plant_id, x.sn
    )
    select d.plant_id, d.sn, d.dev, s.last_dev as prev, s.stale, s.stale_key, s.clear_at
      from d left join private.inverter_alert_state s on s.plant_id = d.plant_id and s.sn = d.sn
  loop
    if r.prev is null then
      insert into private.inverter_alert_state as s (plant_id, sn, last_dev) values (r.plant_id, r.sn, r.dev)
      on conflict (plant_id, sn) do update set last_dev = greatest(s.last_dev, excluded.last_dev);
    elsif r.dev > r.prev then
      clr := case when r.stale then case when r.clear_at is null or r.dev - r.prev > 600 then r.dev else r.clear_at end end;
      if r.stale and extract(epoch from now()) - r.dev <= 900 and r.dev - clr >= 900 then
        perform private.email_enqueue_plant(r.plant_id, 'logger_back', 'logger_back:' || substr(r.stale_key, 14),
          jsonb_build_object('since', regexp_replace(r.stale_key, '^.*:', '')::bigint, 'at', clr,
                             'inverter', coalesce((select nullif(m.alias, '') from plants.meta_info m where m.sn = r.sn), 'Inverter ' || r.sn)),
          r.stale_key);
        update private.inverter_alert_state set last_dev = r.dev, stale = false, stale_key = null, clear_at = null
         where plant_id = r.plant_id and sn = r.sn;
      else
        update private.inverter_alert_state set last_dev = r.dev, clear_at = clr where plant_id = r.plant_id and sn = r.sn;
      end if;
    end if;
  end loop;

  -- Everything else from one read of the minute's readings. Grid present is
  -- q_grid_present's rule (0055): over 100 V among the rows with the newest
  -- device_time; null when nobody reported a voltage.
  for r in
    with rd as (
      select x.plant_id, x.sn, x.device_time, x.grid_volt_v, x.batt_temp_c, x.batt_soc
        from public.readings x where x.plant_id = any (todo) and x.ts = p_ts
    ), newest as (
      select plant_id, max(device_time) as dt from rd where grid_volt_v is not null group by plant_id
    )
    select c.plant_id, jsonb_build_object(
             'present', case when count(rd.grid_volt_v) = 0 then null
                             else coalesce(bool_or(public.grid_live(rd.grid_volt_v)) filter (
                                    where rd.grid_volt_v is not null and rd.device_time is not distinct from n.dt), false) end,
             'dev', max(case when rd.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
                             then extract(epoch from (rd.device_time::timestamp at time zone plants.tz(c.plant_id)))::bigint end),
             'temp', max(rd.batt_temp_c) filter (where rd.batt_temp_c > 0 and rd.batt_temp_c < 80),
             'spread', case when count(distinct rd.sn) filter (where rd.batt_soc between 1 and 100) >= 2
                            then max(rd.batt_soc) filter (where rd.batt_soc between 1 and 100)
                               - min(rd.batt_soc) filter (where rd.batt_soc between 1 and 100) end,
             'has_batt', coalesce(c.has_battery, true),
             'shared', coalesce(c.battery_banks = 'shared', false)) as f
      from plants.settings c
      join rd on rd.plant_id = c.plant_id
      left join newest n on n.plant_id = c.plant_id
     where c.plant_id = any (todo)
     group by c.plant_id, c.has_battery, c.battery_banks
  loop
    begin
      perform private.email_plant_apply(r.plant_id, p_ts, r.f);
    exception when others then
      failed := failed || jsonb_build_object('plant', r.plant_id, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('plants', coalesce(array_length(todo, 1), 0), 'failed', failed);
end $function$;

CREATE OR REPLACE FUNCTION public.job_check_inputs()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  d    date := (now() at time zone plants.market_tz())::date;
  m    private.job_check_mark;
  c    bigint; f bigint;
  jobs jsonb := '[]';
  fn_calls_state jsonb := '[]';
begin
  select x.calls, x.failed into c, f from plants.calls_on(d) x;
  select * into m from private.job_check_mark for update;
  insert into private.job_check_mark as t values (true, now(), d, c, f)
    on conflict (id) do update set at = excluded.at, day = excluded.day, calls = excluded.calls, failed = excluded.failed;

  if to_regclass('cron.job') is not null then
    with starts as (                                                     -- 0234
      select r.jobid, max(r.start_time) as last_start from cron.job_run_details r group by r.jobid
    ), ends as (                                                         -- 0234
      select distinct on (r.jobid) r.jobid, r.status, r.end_time, r.return_message
        from cron.job_run_details r
       where r.status in ('succeeded', 'failed')
       order by r.jobid, r.start_time desc
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'job', j.jobname, 'schedule', j.schedule, 'active', j.active,
             'last_start', s.last_start,                                 -- 0234
             'last_status', l.status,
             'last_end', l.end_time,
             'message', left(regexp_replace(coalesce(l.return_message, ''), '[^\s"''<>@]+@[^\s"''<>@]+\.[a-z]{2,}', '[email]', 'gi'), 200))
             order by j.jobname), '[]')
      into jobs
      from cron.job j
      left join starts s on s.jobid = j.jobid                            -- 0234
      left join ends l on l.jobid = j.jobid;                             -- 0234
  end if;

  delete from private.fn_calls where at < now() - interval '2 days';
  if to_regclass('net._http_response') is not null then
    fn_calls_state := private.fn_call_states();
  end if;

  return jsonb_build_object(
    'now', now(),
    'shards', (select coalesce(jsonb_agg(jsonb_build_object('shard', s.shard,
                 'last_at', plants.run_last_at(s.shard, d - 1))
                 order by s.shard), '[]')
                 from private.poll_shards() s),
    'jobs', jobs,
    'calls', fn_calls_state,
    'vendor', jsonb_build_object(
      'calls', case when m.day = d then c - m.calls else c end,
      'failed', case when m.day = d then f - m.failed else f end,
      'since', m.at),
    'email', (select jsonb_build_object('waiting', count(*), 'oldest_due', min(due_at))
                from public.email_queue where status = 'queued' and due_at <= now() - interval '10 minutes'),
    'checks', (select coalesce(jsonb_object_agg(name, jsonb_build_object('failing', failing, 'since', since)), '{}')
                 from private.job_checks));
end $function$;

CREATE OR REPLACE FUNCTION public.brand_tally(p_brand text, p_rows jsonb, p_shard integer, p_run_ms integer, p_plants integer)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  insert into plants.brand_calls as t (day, brand, kind, result, calls, ms_total, ms_max, plants, last_at)
  select (now() at time zone plants.market_tz())::date, x.brand, x.kind, x.result,
         sum(x.calls), sum(x.ms), max(x.ms_max), sum(x.plants), now()
    from (select coalesce(p_brand, '') as brand, r.kind, r.result, r.calls, r.ms, r.ms_max, 0::bigint as plants
            from jsonb_to_recordset(coalesce(p_rows, '[]')) as r(kind text, result text, calls bigint, ms bigint, ms_max int)
           where r.kind is not null and r.result is not null
          union all
          select '', 'poll_run', 's' || p_shard, 1, p_run_ms, p_run_ms, p_plants
           where p_shard is not null) x
   group by x.brand, x.kind, x.result
   order by x.brand, x.kind, x.result
  on conflict (day, brand, kind, result) do update set
    calls    = t.calls + excluded.calls,
    ms_total = t.ms_total + excluded.ms_total,
    ms_max   = greatest(t.ms_max, excluded.ms_max),
    plants   = t.plants + excluded.plants,
    last_at  = excluded.last_at;
$function$;

CREATE OR REPLACE FUNCTION public.brand_calls_report()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  d date := (now() at time zone plants.market_tz())::date - 1;
  out jsonb;
begin
  delete from plants.brand_calls where day < d - 400;
  if not exists (select 1 from plants.brand_calls where day = d) then return null; end if;

  with c as (select * from plants.brand_calls where day = d and kind <> 'poll_run'),
       r as (select * from plants.brand_calls where day = d and kind = 'poll_run'),
       tot as (
         select coalesce(sum(calls), 0) as calls,
                coalesce(sum(calls) filter (where result in ('429', '403_throttle', '5xx', 'network', 'timeout')), 0) as failed,
                coalesce(sum(ms_total), 0) as ms
           from c),
       pl as (select coalesce(sum(plants::numeric / nullif(calls, 0)), 0) as plants,
                     coalesce(sum(calls), 0) as runs,
                     coalesce(max(ms_max), 0) as slowest_ms
                from r)
  select jsonb_build_object(
           'day', d,
           'calls', tot.calls,
           'failed', tot.failed,
           'error_rate', round(tot.failed::numeric / nullif(tot.calls, 0), 4),
           'avg_call_ms', round(tot.ms::numeric / nullif(tot.calls, 0)),
           'plants', round(pl.plants, 1),
           'calls_per_plant', round(tot.calls / nullif(pl.plants, 0)),
           'poll_runs', pl.runs,
           'slowest_run_ms', pl.slowest_ms,
           'by_result', (select coalesce(jsonb_object_agg(result, n), '{}') from
                           (select result, sum(calls) as n from c group by result) x),
           'by_kind', (select coalesce(jsonb_object_agg(kind, n), '{}') from
                         (select kind, sum(calls) as n from c group by kind) y))
    into out
    from tot, pl;
  return out;
end $function$;

CREATE OR REPLACE FUNCTION public._energy_row(p_bucket text, p_period date, p_pv double precision, p_load double precision, p_imp double precision, p_exp double precision, p_chg double precision, p_dischg double precision)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  select jsonb_build_object(
    'pv', p_pv, 'load', p_load, 'imp', p_imp, 'exp', p_exp,
    'chg', p_chg, 'dischg', p_dischg,
    -- self-sufficiency: share of load not met by imported grid energy
    'selfSuff', round(public.independence_pct(p_load, p_imp)))   -- R23: the one independence
  || case when p_bucket = 'day' then
       jsonb_build_object(
         'time', to_char(p_period, 'YYYY-MM-DD'),
         'date', to_char(p_period, 'YYYY-MM-DD'),
         'day', extract(day from p_period)::int,
         'dow', extract(dow from p_period)::int,
         'label', to_char(p_period, 'Dy'),
         'monthLabel', to_char(p_period, 'Mon'))
     else
       -- the brand's year endpoint returns zero-padded month numbers ("05"), and the
       -- charts key off this string, so pad rather than emitting "5"
       jsonb_build_object(
         'time', to_char(p_period, 'MM'),
         'date', to_char(p_period, 'MM'),
         'day', to_char(p_period, 'Mon'),
         'label', to_char(p_period, 'Mon'),
         'monthLabel', to_char(p_period, 'Mon'))
     end
$function$;

CREATE OR REPLACE FUNCTION public.email_plant_events(p_plant bigint)
 RETURNS TABLE(kind text, key text, data jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with
  pz as (select public.plant_tz(p_plant) as tz),
  now_s as (select extract(epoch from now())::bigint as t),
  cfg as (select coalesce((select has_grid from plants.settings where plant_id = p_plant), true) as has_grid,
                 coalesce((select has_battery from plants.settings where plant_id = p_plant), true) as has_battery,
                 (select battery_banks from plants.settings where plant_id = p_plant) as banks),
  loc as (select public.today_tz((select tz from pz)) as day,
                 extract(hour from timezone((select tz from pz), now()))::int as hour),
  day_lo as (select public.day_start_epoch_tz((select day from loc), (select tz from pz)) as lo),

  -- Grid. Minutes where presence is unknown are skipped, as in 0057.
  grid_known as (
    select r.ts, public.q_grid_present(p_plant, r.ts) as present
      from (select distinct ts from public.readings, now_s where plant_id = p_plant and ts >= now_s.t - 1800) r
  ),
  gk as (select ts, present from grid_known where present is not null),
  grid as (
    select (select count(*) = 3 and bool_and(not present) from (select present from gk order by ts desc limit 3) x) as down,
           (select count(*) = 2 and bool_and(present) from (select present from gk order by ts desc limit 2) x) as up,
           (select max(ts) from gk where present) as last_on,
           (select max(ts) from gk where not present) as last_off
  ),

  -- Battery temperature: the hottest inverter at the newest reading.
  hot as (
    select r.ts, r.batt_temp_c as temp from public.readings r, now_s
     where r.plant_id = p_plant and r.ts >= now_s.t - 600 and r.batt_temp_c > 0 and r.batt_temp_c < 80
     order by r.ts desc, r.batt_temp_c desc limit 1
  ),

  -- Charge spread between inverters' batteries, minute by minute, over the last hour.
  bank as (
    select r.ts, max(r.batt_soc) - min(r.batt_soc) as spread
      from public.readings r, now_s
     where r.plant_id = p_plant and r.ts >= now_s.t - 3600 and r.batt_soc between 1 and 100
     group by r.ts
    having count(distinct r.sn) >= 2
  ),
  drift as (select count(*) >= 30 and max(ts) - min(ts) >= 3300 and min(spread) >= 10 as drifting, max(ts) as ts from bank),

  -- Strings: 0057's dead_held, bounded to the window.
  str_latest as (select max(ts) as ts from public.strings, now_s where plant_id = p_plant and ts >= now_s.t - 900),
  dead_held as (
    select s.sn, s.no from public.strings s, loc, now_s
     where s.plant_id = p_plant and loc.hour between 11 and 14 and s.ts >= now_s.t - 900
       and coalesce(s.volt_v, 0) < 1.5 and coalesce(s.power_w, 0) < 5
       and exists (select 1 from public.strings o where o.plant_id = p_plant and o.ts = s.ts and o.sn = s.sn and o.no is distinct from s.no and coalesce(o.power_w, 0) > 200)
     group by s.sn, s.no
    having count(*) >= 12
       and exists (select 1 from public.strings cur, str_latest where cur.plant_id = p_plant and cur.ts = str_latest.ts and cur.sn = s.sn and cur.no = s.no and coalesce(cur.volt_v, 0) < 1.5 and coalesce(cur.power_w, 0) < 5)
  ),
  dead1 as (
    select d.sn, d.no, coalesce(nullif(m.alias, ''), 'Inverter ' || d.sn) as inverter
      from dead_held d left join plants.meta_info m on m.sn = d.sn
     order by m.ord nulls last, d.sn, d.no limit 1
  ),

  -- the brand's own clock: the newest device_time across the plant, read only from
  -- rows our polls wrote in the last 3 minutes. No such rows: our polls are failing,
  -- which is not the inverter going quiet, so no logger row at all.
  dev as (
    select max(extract(epoch from (r.device_time::timestamp at time zone (select tz from pz))))::bigint as last_dev
      from public.readings r, now_s
     where r.plant_id = p_plant and r.ts >= now_s.t - 180
       and r.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
  )

  select 'grid_down', 'grid_down:' || p_plant || ':' || x.since,
         jsonb_build_object('since', x.since, 'chargePct', x.soc)
    from (select (select min(ts) from gk where not present and ts > coalesce(grid.last_on, 0)) as since,
                 (select public.soc_at(p_plant, now_s.t) from now_s) as soc   -- R23: the one battery %
            from grid where grid.down) x, cfg
   where cfg.has_grid
  union all
  select 'grid_on', 'grid_on:' || p_plant,
         jsonb_build_object('since', (select min(ts) from gk where present and ts > coalesce(grid.last_off, 0)))
    from grid, cfg where grid.up and cfg.has_grid
  union all
  select 'batt_hot', 'batt_hot:' || p_plant || ':' || (select day from loc),
         jsonb_build_object('at', hot.ts, 'tempC', round(hot.temp)::int)
    from hot, cfg where hot.temp > 40 and cfg.has_battery
  union all
  select 'bank_drift', 'bank_drift:' || p_plant || ':' || (select day from loc),
         jsonb_build_object('banks', (
           select jsonb_agg(jsonb_build_object('name', coalesce(nullif(m.alias, ''), 'Inverter ' || r.sn), 'chargePct', round(r.batt_soc)::int)
                            order by m.ord nulls last, r.sn)
             from public.readings r left join plants.meta_info m on m.sn = r.sn
            where r.plant_id = p_plant and r.ts = drift.ts and r.batt_soc between 1 and 100))
    from drift, cfg where drift.drifting and cfg.has_battery and cfg.banks is distinct from 'shared'
  union all
  select 'string_dead', 'string_dead:' || p_plant || ':' || (select day from loc),
         jsonb_build_object('string', 'String ' || dead1.no, 'inverter', dead1.inverter,
           -- the minute after it last had voltage today; 15 min ago when it never did
           'since', coalesce((select max(s.ts) + 60 from public.strings s, day_lo
                               where s.plant_id = p_plant and s.sn = dead1.sn and s.no = dead1.no
                                 and s.ts >= day_lo.lo and coalesce(s.volt_v, 0) >= 1.5),
                             (select t - 900 from now_s)))
    from dead1
  union all
  select 'logger_stale', 'logger_stale:' || p_plant || ':' || dev.last_dev, jsonb_build_object('since', dev.last_dev)
    from dev, now_s where now_s.t - dev.last_dev > 900
  union all
  select 'logger_ok', 'logger_ok:' || p_plant, jsonb_build_object('at', dev.last_dev)
    from dev, now_s where now_s.t - dev.last_dev <= 900
$function$;

CREATE OR REPLACE FUNCTION private.poll_shards(p_per_shard integer DEFAULT 25)
 RETURNS TABLE(shard integer, shards integer, delay_ms integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_temp'
AS $function$
  with n as (
    select greatest(1, ceil(count(*)::numeric / greatest(p_per_shard, 1)))::int as shards
      from plants.login_info
     where status = 'ok'
  )
  -- 0, 2 or 4 s past the minute (SOLAR-681 R21): spread enough for the start, and every
  -- reading saved before its page asks at 12-42 s (it was 0/10/20 s)
  select s.i, n.shards, (s.i % 3) * 2000
    from n, generate_series(0, n.shards - 1) as s(i)
$function$;

CREATE OR REPLACE FUNCTION private.alerts_minute()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  last_done bigint := (select c.value::bigint from public.app_config c where c.key = 'ALERTS_DONE_TS');
  -- two minutes back: every read of that minute has saved or given up by then (50 s deadline)
  upto bigint := (floor(extract(epoch from now()) / 60) * 60)::bigint - 120;
  m bigint;
  n int := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('private.alerts_minute')) then return jsonb_build_object('busy', true); end if;
  m := greatest(coalesce(last_done, upto - 60), upto - 600) + 60;
  while m <= upto loop
    perform public.email_poll_step(m, '[]'::jsonb, array(select distinct a.plant_id from public.agg_minute a where a.ts = m order by 1));
    insert into public.app_config (key, value, note) values ('ALERTS_DONE_TS', m, 'the last minute the alert step ran for (private.alerts_minute)')
    on conflict (key) do update set value = excluded.value;
    n := n + 1;
    m := m + 60;
  end loop;
  return jsonb_build_object('minutes', n, 'upto', upto);
end $function$;

CREATE OR REPLACE FUNCTION private.schedule_jobs()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'pg_temp'
AS $function$
declare j record;
begin
  -- pg_cron keys a job by name and user: run as anyone else, every job would be made twice
  if current_user <> 'postgres' then
    raise exception 'run private.schedule_jobs() as postgres, not %', current_user using errcode = '42501';
  end if;
  for j in select * from (values
    ('agg-minute-rollup',    '40 4 * * *',         $c$select private.agg_minute_rollup(31)$c$),
    ('alerts',               '* * * * *',          $c$select private.alerts_minute()$c$),
    ('plant-check',          '* * * * *',          $c$select private.plant_checks()$c$),
    ('plant-sync',           '* * * * *',          $c$select private.call_fn('plant-jobs', '{"task":"sync"}', 55000)$c$),
    ('temps',                '* * * * *',          $c$select private.call_fn('plant-jobs', '{"task":"temps"}', 55000)$c$),
    ('billing-delete',       '*/5 * * * *',        $c$select billing.delete_due()$c$),
    ('billing-history',      '* * * * *',          $c$select private.call_fn('recover?queue=1', '{}', 60000)$c$),
    ('billing-run',          '*/5 4-5 * * *',      $c$select private.call_fn('billing/run', '{}', 120000)$c$),
    ('ensure-partitions',    '0 3 * * *',          $c$select private.ensure_partitions()$c$),
    ('first-load-continue',  '*/2 * * * *',        $c$select private.first_load_continue()$c$),
    ('grid-off',             '10 4 * * *',         $c$select private.grid_off_update_all()$c$),
    ('history-delete',       '* * * * *',          $c$call private.history_delete_run()$c$),
    ('history-delete-slow',  '*/15 * * * *',       $c$call private.history_delete_check()$c$),
    ('job-check',            '2-59/5 * * * *',     $c$select private.call_fn('job-check', '{}', 30000)$c$),
    ('notify-email',         '* * * * *',          $c$select private.call_fn('notify-email', '{}', 55000)$c$),
    ('notify-push',          '* * * * *',          $c$select private.call_fn('notify-push', '{}', 55000)$c$),
    ('purge-cron-log',       '45 4 * * *',         $c$delete from cron.job_run_details where end_time < now() - make_interval(days => 7)$c$),
    ('rollup-old-days',      '*/5 5-7 * * *',      $c$call private.rollup_old_days(31)$c$),
    ('plant-energy',         '15 2 * * *',         $c$select private.call_fn('sync-plant-energy', '{}', 150000)$c$),
    ('reader',               '* * * * *',          $c$select private.call_fn('poll', jsonb_build_object('shard', s.shard, 'shards', s.shards, 'delay_ms', s.delay_ms), 55000) from private.poll_shards() s$c$),
    ('recover',              '5 4,10,16,22 * * *', $c$select private.call_fn('recover', '{}', 150000)$c$)
  ) t(name, sched, cmd) loop
    perform cron.schedule(j.name, j.sched, j.cmd);   -- by name: an existing job is updated in place
  end loop;
  -- the names before SOLAR-681 R16: gone, so no job runs twice
  perform cron.unschedule(jobname) from cron.job where jobname in ('sunsynk-poll', 'sunsynk-recover', 'sunsynk-plant-energy');
end $function$;

-- the jobs as their latest list has them (private.schedule_jobs above)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then perform private.schedule_jobs(); end if;
end $$;
