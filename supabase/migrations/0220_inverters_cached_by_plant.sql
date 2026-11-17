-- SOLAR-575: a plant two logins can see read once an hour.
--
-- private.inverters keeps one account_id per serial: whichever login committed or
-- seeded it last. poll_jobs gives each plant to one login (A), but the hourly plant
-- sync of another login (B) polls the plant too and files its serials under B.
-- inverters_cached(A) then had none of them, so A took the live path every minute:
-- inverter list + plant list + every endpoint, no last row to carry or tier from.
-- On the mock that call burst hit the per-request limit, nothing committed, A never
-- took the serials back, and only B's minute-0 poll wrote a row.
--
-- Now a login's cache also holds the inverters of every plant it is linked to,
-- whoever's account_id they carry. The poller still keeps only the plants its jobs
-- name, so B's extra rows are filtered out as before.

create or replace function public.inverters_cached(p_account uuid)
returns table(sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text, gsn text, comm_type text, plant_name text, ord integer, status integer, last_reading jsonb, carried_run integer)
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
         coalesce(cr.n, 0)::integer as carried_run
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
   where i.account_id = p_account
      or i.plant_id in (select pu.plant_id from public.plant_users pu where pu.account_id = p_account)
   order by coalesce(m.ord, 9999), i.sn;
end $$;
