-- SOLAR-612: skip the slave's input check until its next upload is due.
--
-- A slave logger uploads every 5 minutes, so poll's input call finds nothing new four
-- minutes in five. inverters_cached now also returns upload_s: the smaller of the last
-- two gaps between distinct device_time values (last 20 rows, past 24 h). Null until
-- three uploads are known. Poll skips the check while carried_run + 2 < upload_s / 60.
-- device_time is text: only 'YYYY-MM-DD HH:MM:SS' values are cast, so a stray value
-- gives null instead of failing every poll.

drop function if exists public.inverters_cached(uuid);

create function public.inverters_cached(p_account uuid)
returns table(sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text, gsn text, comm_type text, plant_name text, ord integer, status integer, last_reading jsonb, carried_run integer, upload_s integer)
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
  select i.sn, i.plant_id, m.alias, m.model, m.soft_ver, m.hmi_ver,
         m.gsn, m.comm_type, m.plant_name, m.ord, m.status,
         lr.row as last_reading,
         coalesce(cr.n, 0)::integer as carried_run,
         ug.s as upload_s
    from private.inverters i
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
   where i.account_id = p_account
      or i.plant_id in (select pu.plant_id from public.plant_users pu where pu.account_id = p_account)
   order by coalesce(m.ord, 9999), i.sn;
end $$;

revoke all on function public.inverters_cached(uuid) from public, anon, authenticated;
grant execute on function public.inverters_cached(uuid) to service_role;
