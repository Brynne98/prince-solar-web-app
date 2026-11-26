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
  perform 1 from private.sunsynk_accounts sa where sa.id = any (accts) order by sa.id for update;
  -- the newer token wins (0250): the last object with the latest expiry, when not older than the stored one
  update private.sunsynk_accounts sa
     set access_token = case when t.expires >= coalesce(sa.access_expires_at, 0) then t.access else sa.access_token end,
         access_expires_at = greatest(t.expires, coalesce(sa.access_expires_at, 0)),
         last_ok_at = now(), last_error = null
    from (select distinct on (b.account) b.account, b.access, b.expires from _bin b
           order by b.account, b.expires desc nulls last, b.i desc) t
   where sa.id = t.account;

  -- 2. plants in id order, for share; a plant whose history was deleted for no key update,
  -- since step 8 updates it (two batches holding it for share would deadlock there). Then
  -- the version each read started on (looked up under the plant's own id, as write_allowed
  -- does) and read_now.
  for pl in select bp.id, bp.history_purged_at is not null as purged from billing.plants bp
            where bp.id in (select k::bigint from _bin b cross join jsonb_object_keys(b.versions) k)
            order by bp.id loop
    if pl.purged then
      perform 1 from billing.plants where id = pl.id for no key update;
    else
      perform 1 from billing.plants where id = pl.id for share;
    end if;
  end loop;
  create temp table _bok on commit drop as
    with v as (select distinct b.i, k::bigint as plant, b.versions->>(k::bigint::text) as version
                 from _bin b cross join jsonb_object_keys(b.versions) k)
    select v.i, v.plant from v
     where v.plant in (select pr from billing.plants_read_now(array(select distinct plant from v), p_at) pr)
       and exists (select 1 from billing.plants bp where bp.id = v.plant and bp.version = v.version::bigint);
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
  perform 1 from private.meta m
   where m.sn in (select (t.rw).sn from _bst t
                  union select e->>'sn' from _bin b cross join jsonb_array_elements(b.meta) e)
   order by m.sn for no key update;
  -- poll_commit_v2 updates an inverter's string records only once its meta row exists: from the
  -- batch's start (avail 0), or from the object after the first one that sent its meta
  create temp table _bme on commit drop as
    select m.sn, 0 as avail from private.meta m where m.sn in (select (t.rw).sn from _bst t);
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
     and not exists (select 1 from private.meta m join _bme x on x.sn = m.sn
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
end $function$;
