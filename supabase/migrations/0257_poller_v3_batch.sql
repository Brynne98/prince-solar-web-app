-- ============================================================================
-- 0257 — poller v3, database half (SOLAR-656; design reports/poller-v3-design.md, sections 3-4).
--
-- Nothing calls the new functions yet: today's poller (poll_jobs_v2, poll_commit_v2,
-- write_allowed) is unchanged. The edge lanes (part 3) will call them.
--
--   private.read_second(key)    a login's read second: hash of its id mod 60. The share
--                               login, and a login reading over 10 inverters, read each
--                               plant on the second of its plant id.
--   billing.accounts_live       account_status's "reads now" facts for many accounts in one
--                               query: live, must_choose and ends_at, the earliest time the
--                               clock alone can end it (free week, plan end, pay-by date,
--                               grant end). renewal_hold runs only for a plan past its pay-by
--                               date, as in account_status.
--   billing.plants_read_now     plant_state's read_now for many plants in one query.
--   billing.write_allowed_set   write_allowed (0246) without the per-plant loop.
--   billing.reading_routes_set  reading_routes (0246) without account_status per account,
--                               plus ends_at (the account's, or the seat's closed_at).
--   public.poll_routes(seconds) poll_jobs_v2's plant-to-login pick for the plants read on
--                               those seconds: version, time zone, battery sign, has_grid,
--                               ends_at, read second.
--   public.poll_commit_batch    many logins' minute in one transaction, every rule of
--                               poll_commit (0250) and poll_commit_v2 (0246). Locks logins,
--                               then plants (account_mark's order), then rows in key order.
--                               Returns one result per input row; on an error the whole
--                               batch rolls back and the caller saves login by login.
--   public.sunsynk_tally        rows summed per key and written in key order: concurrent
--                               callers no longer deadlock (0178).
-- ============================================================================

create function private.read_second(p_key text)
returns int language sql immutable set search_path = pg_temp as $$
  select ('x' || '0' || left(md5(p_key), 7))::bit(32)::int % 60
$$;

-- ---------------------------------------------------------------------------
-- account_status (0254) for many accounts, only what reading needs. The state rules
-- are account_status's, line for line: the latest plan begun by `at`, then grants, then
-- the free week. live = trialing, active or past_due.
-- ends_at: the earliest future time at which the clock alone may end the account's
-- reading. It may be early (a grant ending can leave the plan running); never late.
-- ---------------------------------------------------------------------------
create function billing.accounts_live(p_accounts uuid[], p_at timestamptz)
returns table (account uuid, live boolean, must_choose boolean, ends_at timestamptz)
language sql stable set search_path = billing, pg_temp as $$
  with a as (
    select a.id, a.trial_started_at, a.trial_ends_at, m.retry_days, m.trial_places,
           coalesce(a.time_zone, m.default_time_zone) as tz
      from billing.accounts a join billing.markets m on m.code = a.market
     where a.id = any (p_accounts)
  ), s as (
    select distinct on (s.account) s.*
      from billing.subscriptions s
     where s.account = any (p_accounts) and s.started_at <= p_at
     order by s.account, s.started_at desc
  ), g as (
    select g.account,
           coalesce(sum(g.places) filter (where g.starts_at <= p_at and (g.ends_at is null or g.ends_at > p_at)), 0) as places,
           min(g.ends_at) filter (where g.starts_at <= p_at and g.ends_at > p_at) as next_end
      from billing.grants g
     where g.account = any (p_accounts)
     group by g.account
  ), se as (
    select se.account, count(*) as chosen
      from billing.seats se
     where se.account = any (p_accounts) and se.chosen_at <= p_at and (se.closed_at is null or se.closed_at > p_at)
     group by se.account
  ), x as (
    select a.*, s.id as sub, s.status, s.ended_at, s.cancel_at_period_end, s.period_end, s.extra_places, s.plan,
           case when s.status = 'past_due' then s.past_due_since end as pds,
           coalesce(g.places, 0) as grant_places, g.next_end as grant_end, coalesce(se.chosen, 0) as chosen
      from a
      left join s on s.account = a.id
      left join g on g.account = a.id
      left join se on se.account = a.id
  ), y as (
    select x.*, billing.past_due_cutoff(x.pds, x.retry_days, x.tz) as cutoff from x
  ), z as (
    select y.*,
           case when y.sub is null then null
                when y.status = 'ended' then y.ended_at
                when y.cancel_at_period_end and y.period_end <= p_at then y.period_end
                -- a payment made before the cutoff and not answered yet keeps it running, at most a day
                when y.pds is not null and y.cutoff <= p_at
                     and not (select h.in_flight from billing.renewal_hold(y.id, p_at) h) then y.cutoff
           end as sub_end
      from y
  ), e as (
    select z.*,
           case when z.sub is null then null
                when z.sub_end is not null and z.sub_end <= p_at then 'ended'
                when z.pds is not null and z.pds <= p_at then 'past_due'
                else 'active' end as eff
      from z
  ), st as (
    select e.*,
           case when e.eff in ('active', 'past_due') then e.eff
                when e.grant_places > 0 then 'active'
                when e.trial_started_at <= p_at and p_at < e.trial_ends_at then 'trialing' end as state,
           coalesce(case when e.eff in ('active', 'past_due')
                           then (select p.places from billing.plans p where p.code = e.plan) + e.extra_places + e.grant_places
                         when e.grant_places > 0 then e.grant_places
                         when e.trial_started_at <= p_at and p_at < e.trial_ends_at then e.trial_places end, 0) as places
      from e
  )
  select st.id,
         st.state is not null,
         st.state is not null and st.chosen > st.places,
         case when st.state is not null then
           least(case when st.eff in ('active', 'past_due') then
                   least(case when st.status = 'ended' and st.ended_at > p_at then st.ended_at end,
                         case when st.cancel_at_period_end and st.period_end > p_at then st.period_end end,
                         case when st.pds is not null and st.cutoff > p_at then st.cutoff end,
                         -- held past the cutoff by a payment not answered yet: 24 hours at most (renewal_hold)
                         case when st.pds is not null and st.cutoff <= p_at then st.cutoff + interval '24 hours' end)
                 end,
                 case when st.state = 'trialing' then st.trial_ends_at end,
                 st.grant_end)
         end
    from st
$$;

-- plant_state(plant, at)->read_now for many plants: an open seat on a live account not
-- over its places, with an ok login or a claim that reaches the plant (has_route, true).
create function billing.plants_read_now(p_plants bigint[], p_at timestamptz)
returns setof bigint language sql stable set search_path = billing, pg_temp as $$
  with se as (
    select s.account, s.plant from billing.seats s
     where s.plant = any (p_plants) and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  ), st as (
    select * from billing.accounts_live(array(select distinct account from se), p_at)
  )
  select distinct se.plant
    from se join st on st.account = se.account and st.live and not st.must_choose
   where exists (select 1 from billing.logins l join billing.login_plants lp on lp.login = l.id
                  where l.account = se.account and lp.plant = se.plant and lp.gone_at is null and l.status = 'ok')
      or exists (select 1 from billing.plant_claims c where c.account = se.account and c.plant = se.plant)
$$;

-- write_allowed (0246), set-based. Locks the plant rows for share in id order.
create function billing.write_allowed_set(p_versions jsonb, p_at timestamptz)
returns bigint[] language plpgsql set search_path = billing, pg_temp as $$
declare ids bigint[];
begin
  ids := array(select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k);
  perform 1 from billing.plants where id = any (ids) order by id for share;
  return array(select bp.id from billing.plants bp
                where bp.id = any (ids)
                  and bp.version = (p_versions->>(bp.id::text))::bigint
                  and bp.id in (select billing.plants_read_now(ids, p_at))
                order by bp.id);
end $$;

-- reading_routes (0246), set-based, plus ends_at: the account's, or the seat's closing time.
create function billing.reading_routes_set(p_at timestamptz)
returns table (plant bigint, account uuid, lane uuid, via_share boolean, since timestamptz, ends_at timestamptz)
language sql stable set search_path = billing, private, pg_temp as $$
  with seat as (
    select s.account, s.plant, s.closed_at from billing.seats s
     where s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  ), live as (
    select st.account, st.ends_at
      from billing.accounts_live(array(select distinct account from seat), p_at) st
     where st.live and not st.must_choose
  )
  select se.plant, se.account, l.id, false, l.created_at, least(lv.ends_at, se.closed_at)
    from seat se join live lv on lv.account = se.account
    join billing.logins l on l.account = se.account and l.status = 'ok'
    join billing.login_plants lp on lp.login = l.id and lp.plant = se.plant and lp.gone_at is null
    join private.sunsynk_accounts sa on sa.id = l.id and sa.status = 'active'
  union all
  select se.plant, se.account, sa.id, true, c.claimed_at, least(lv.ends_at, se.closed_at)
    from seat se join live lv on lv.account = se.account
    join billing.plant_claims c on c.plant = se.plant and c.account = se.account
    join private.sunsynk_accounts sa on sa.kind = 'share' and sa.status = 'active'
$$;

-- ---------------------------------------------------------------------------
-- The plants read on these seconds, each through poll_jobs_v2's login (0246's pick:
-- logins before claims, the earliest first). One query for the whole fleet.
-- ---------------------------------------------------------------------------
create function public.poll_routes(p_seconds int[], p_at timestamptz default now())
returns table (plant_id bigint, account_id uuid, plant_version bigint, timezone text,
               batt_positive_means text, has_grid boolean, ends_at timestamptz, read_second int)
language sql stable security definer set search_path = public, private, pg_temp as $$
  with pick as (
    select distinct on (r.plant) r.plant, r.lane, r.ends_at
      from billing.reading_routes_set(p_at) r
     order by r.plant, r.via_share, r.since, r.lane
  ), pk as (
    select p.plant, p.lane, p.ends_at, bp.version from pick p join billing.plants bp on bp.id = p.plant
  ), lane_inv as (
    select pk.lane, count(i.sn) as n
      from pk left join private.inverters i on i.plant_id = pk.plant
     group by pk.lane
  ), sec as (
    select pk.*, case when sa.kind = 'share' or li.n > 10 then private.read_second(pk.plant::text)
                      else private.read_second(pk.lane::text) end as s
      from pk
      join private.sunsynk_accounts sa on sa.id = pk.lane
      join lane_inv li on li.lane = pk.lane
  )
  select sec.plant, sec.lane, sec.version, coalesce(c.timezone, 'Africa/Johannesburg'), c.batt_positive_means,
         c.has_grid, sec.ends_at, sec.s
    from sec left join public.plant_config c on c.plant_id = sec.plant
   where sec.s = any (p_seconds)
   order by sec.plant
$$;

-- ---------------------------------------------------------------------------
-- poll_commit_batch: one minute (p_ts) for many logins. p_rows, one object per login:
--   {account, versions: {"<plant>": <version the read started on>}, readings, strings,
--    agg, meta, inverters, access, expires}
-- Same rows and side effects as poll_commit_v2 called once per object in array order:
--   readings/strings for p_ts: the last object's row wins, a concurrent insert's winner is
--     kept; other minutes: the first wins. Within one object the first row wins.
--   agg: the first write wins. gaps over 90 s, refill over 600 s, from max(ts) before the batch.
--   meta and inverters: the last object wins (meta ord/status: the last non-null).
--   token: the newer one (later expiry) wins, saved even when every plant is refused.
-- Lock order: login advisory locks and rows (account_mark's), plants for share, then table
-- rows in key order. Another login's last_ok_at is skipped while that row is locked.
-- Returns (i = 1-based position in p_rows, account, poll_commit_v2's answer).
-- ---------------------------------------------------------------------------
create function public.poll_commit_batch(p_ts bigint, p_rows jsonb, p_at timestamptz default now())
returns table (i int, account uuid, result jsonb)
language plpgsql security definer set search_path = pg_temp as $$
declare
  accts uuid[];
  x uuid;
  t text;
begin
  if not billing.is_live() then
    raise exception 'poll_commit_batch needs billing live (0252)' using errcode = '55000';
  end if;
  -- a second batch in one transaction: the first one's tables are still there
  foreach t in array array['_bin', '_bok', '_brd', '_brw', '_bst', '_bsw', '_bag', '_bgap'] loop
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
  perform 1 from private.sunsynk_accounts sa where sa.id = any (accts) order by sa.id for update;
  -- the newer token wins (0250): the last object with the latest expiry, when not older than the stored one
  update private.sunsynk_accounts sa
     set access_token = case when t.expires >= coalesce(sa.access_expires_at, 0) then t.access else sa.access_token end,
         access_expires_at = greatest(t.expires, coalesce(sa.access_expires_at, 0)),
         last_ok_at = now(), last_error = null
    from (select distinct on (b.account) b.account, b.access, b.expires from _bin b
           order by b.account, b.expires desc nulls last, b.i desc) t
   where sa.id = t.account;

  -- 2. plants for share in id order, then the version each read started on and read_now
  perform 1 from billing.plants bp
   where bp.id in (select k::bigint from _bin b cross join jsonb_object_keys(b.versions) k)
   order by bp.id for share;
  create temp table _bok on commit drop as
    with v as (select b.i, k.key::bigint as plant, k.value as version from _bin b cross join jsonb_each_text(b.versions) k)
    select v.i, v.plant from v
     where v.plant in (select pr from billing.plants_read_now(array(select distinct plant from v), p_at) pr)
       and v.version::bigint = (select bp.version from billing.plants bp where bp.id = v.plant);

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
  perform 1 from private.meta m
   where m.sn in (select (t.rw).sn from _bst t
                  union select e->>'sn' from _bin b cross join jsonb_array_elements(b.meta) e)
   order by m.sn for no key update;
  update private.meta m
     set used_strings = (select array_agg(distinct y order by y)
                           from unnest(m.used_strings || array(
                             select (t.rw).no from _bst t
                              where (t.rw).sn = m.sn
                                and private.string_live((t.rw).volt_v, (t.rw).current_a, (t.rw).power_w, (t.rw).today_kwh))) y)
   where exists (select 1 from _bst t
                  where (t.rw).sn = m.sn and not ((t.rw).no = any (m.used_strings))
                    and private.string_live((t.rw).volt_v, (t.rw).current_a, (t.rw).power_w, (t.rw).today_kwh));
  -- the input count of the last object that sent the inverter
  update private.meta m set string_slots = c.n
    from (select distinct on (q.sn) q.sn, q.n from
            (select (t.rw).sn as sn, t.i, count(*)::int as n from _bst t group by 1, 2) q
           order by q.sn, q.i desc) c
   where m.sn = c.sn and m.string_slots is distinct from c.n;
  delete from _bst t
   where not private.string_live((t.rw).volt_v, (t.rw).current_a, (t.rw).power_w, (t.rw).today_kwh)
     and not exists (select 1 from private.meta m where m.sn = (t.rw).sn and (t.rw).no = any (m.used_strings));
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

  -- 6. meta (only plants written) and inverters (all), the last object winning, in sn order
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
  perform public.inverters_seed(coalesce((
    select jsonb_agg(m.v order by m.sn)
      from (select distinct on (e.v->>'sn') e.v->>'sn' as sn, e.v
              from _bin b cross join jsonb_array_elements(b.inverters) with ordinality e (v, n)
             order by e.v->>'sn', b.i desc, e.n desc) m), '[]'));

  -- 7. the other logins that see these plants were served this minute too
  update private.sunsynk_accounts s set last_ok_at = now()
   where s.id in (select o.id from private.sunsynk_accounts o
                   where o.status = 'active' and o.id <> all (accts)
                     and exists (select 1 from public.plant_users pu
                                  where pu.account_id = o.id and pu.plant_id in (select g.plant from _bag g))
                   order by o.id for update skip locked);
  perform set_config('billing.guarded', 'off', true);

  -- 8. new readings on a deleted plant: it has history again (0246)
  update billing.plants bp set history_purged_at = null
   where bp.history_purged_at is not null
     and exists (select 1 from _bok o join _bin b on b.i = o.i
                  where o.plant = bp.id
                    and (exists (select 1 from jsonb_array_elements(b.readings) e where (e->>'plant_id')::bigint = bp.id)
                         or exists (select 1 from jsonb_array_elements(b.agg) e where (e->>'plant_id')::bigint = bp.id)));

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
end $$;

-- ---------------------------------------------------------------------------
-- sunsynk_tally (0178): rows summed per key and applied in key order, so two callers
-- upserting the same rows wait for each other instead of deadlocking.
-- ---------------------------------------------------------------------------
create or replace function public.sunsynk_tally(p_rows jsonb, p_shard int, p_run_ms int, p_plants int)
returns void language sql security definer set search_path = public, private, pg_temp as $$
  insert into private.sunsynk_calls as t (day, kind, result, calls, ms_total, ms_max, plants, last_at)
  select (now() at time zone 'Africa/Johannesburg')::date, x.kind, x.result,
         sum(x.calls), sum(x.ms), max(x.ms_max), sum(x.plants), now()
    from (select r.kind, r.result, r.calls, r.ms, r.ms_max, 0::bigint as plants
            from jsonb_to_recordset(coalesce(p_rows, '[]')) as r(kind text, result text, calls bigint, ms bigint, ms_max int)
           where r.kind is not null and r.result is not null
          union all
          select 'poll_run', 's' || p_shard, 1, p_run_ms, p_run_ms, p_plants
           where p_shard is not null) x
   group by x.kind, x.result
   order by x.kind, x.result
  on conflict (day, kind, result) do update set
    calls    = t.calls + excluded.calls,
    ms_total = t.ms_total + excluded.ms_total,
    ms_max   = greatest(t.ms_max, excluded.ms_max),
    plants   = t.plants + excluded.plants,
    last_at  = excluded.last_at;
$$;

revoke all on function private.read_second(text) from public, anon, authenticated;
revoke all on function billing.accounts_live(uuid[], timestamptz) from public, anon, authenticated;
revoke all on function billing.plants_read_now(bigint[], timestamptz) from public, anon, authenticated;
revoke all on function billing.write_allowed_set(jsonb, timestamptz) from public, anon, authenticated;
revoke all on function billing.reading_routes_set(timestamptz) from public, anon, authenticated;
revoke all on function public.poll_routes(int[], timestamptz) from public, anon, authenticated;
revoke all on function public.poll_commit_batch(bigint, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.poll_routes(int[], timestamptz) to service_role;
grant execute on function public.poll_commit_batch(bigint, jsonb, timestamptz) to service_role;
