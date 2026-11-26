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
     and not exists (select 1 from private.meta m where m.sn = t.sn and t.no = any(m.used_strings));
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
  update plants.logins
     set access_token = case when p_expires >= coalesce(access_expires_at, 0) then p_access else access_token end,
         access_expires_at = greatest(p_expires, coalesce(access_expires_at, 0)),
         last_ok_at = now(), last_error = null
   where id = p_account;
  -- The other logins that can see these plant_list were served this minute too.
  update plants.logins s
     set last_ok_at = now()
   where s.id in (select o.id from plants.logins o
                   where o.status = 'ok' and o.id <> p_account
                     and exists (select 1 from plants.user_plants pu where pu.account_id = o.id and pu.plant_id = any(plant_list))
                   order by o.id for no key update skip locked);

  return jsonb_build_object(
    'readings', n_readings,
    'strings',  n_strings,
    'plants',   to_jsonb(plant_list),
    'gaps',     to_jsonb(gaps));
end;
$function$;
