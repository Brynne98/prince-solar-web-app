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
