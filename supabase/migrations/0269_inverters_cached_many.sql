-- ============================================================================
-- 0269 — inverters_cached for many logins in one query (SOLAR-656, poller v3).
--
--   inverters_cached_many       inverters_cached (0230) for many logins in one query, for
--                               some plants only; inverters_cached now calls it.
--
-- For the always-on poller (stage 2 of reports/poller-v3-design.md). The edge lanes of
-- stage 1 were dropped after the load test (2026-11-25); nothing calls this yet but
-- inverters_cached.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- inverters_cached for many logins. Same rows as inverters_cached(login) per login, with
-- the login's id first; p_plants (null = all) keeps the inverters of those plants only.
-- ---------------------------------------------------------------------------
create function public.inverters_cached_many(p_accounts uuid[], p_plants bigint[] default null)
returns table(account_id uuid, sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text, gsn text,
              comm_type text, plant_name text, ord integer, status integer, last_reading jsonb, carried_run integer,
              upload_s integer)
language plpgsql
security definer
set search_path = private, pg_temp
as $$
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
          or i.plant_id in (select pu.plant_id from public.plant_users pu where pu.account_id = a.id))
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
end $$;

create or replace function public.inverters_cached(p_account uuid)
returns table(sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text, gsn text, comm_type text, plant_name text, ord integer, status integer, last_reading jsonb, carried_run integer, upload_s integer)
language sql
security definer
set search_path = private, pg_temp
as $$
  select c.sn, c.plant_id, c.alias, c.model, c.soft_ver, c.hmi_ver, c.gsn, c.comm_type, c.plant_name, c.ord, c.status,
         c.last_reading, c.carried_run, c.upload_s
    from public.inverters_cached_many(array[p_account]) c
$$;

revoke all on function public.inverters_cached_many(uuid[], bigint[]) from public, anon, authenticated;
grant execute on function public.inverters_cached_many(uuid[], bigint[]) to service_role;

notify pgrst, 'reload schema';
