-- SOLAR-182: the plant menu shows each plant's state (Setting up %, Live, Stale, Offline).
--
-- api_overview answers for the plant on screen only. api_plant_states answers for every
-- plant of the caller, and only what the menu needs: the last reading, how many inverters
-- reported online in it, and the first-load progress (the same sync object api_overview
-- returns, 0089). The app asks it when the menu opens. A dead login is already known to
-- the app from its logins, so it isn't here.

create or replace function public.api_plant_states()
returns jsonb
language plpgsql
stable security definer
set search_path = public, private, pg_temp
as $$
declare
  -- a variable, not now() in the query, so the planner cuts to the last 2 days
  v_floor bigint := extract(epoch from now())::bigint - 2 * 86400;
  v_out   jsonb := '[]'::jsonb;
  p       record;
  v_ts    bigint;
  v_total int;
  v_on    int;
  v_sync  jsonb;
begin
  for p in select pu.plant_id from public.plant_users pu where pu.user_id = auth.uid() order by pu.linked_at, pu.plant_id loop
    select max(ts) into v_ts from public.readings where plant_id = p.plant_id and ts > v_floor;
    if v_ts is null then
      select max(ts) into v_ts from public.readings where plant_id = p.plant_id;
    end if;
    select count(*), count(*) filter (where rd.status::text in ('1', 'online', 'true'))
      into v_total, v_on
      from public.readings rd where rd.plant_id = p.plant_id and rd.ts = v_ts;

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
                   (pc.temp_next is not null and pc.temp_next < public.today_tz(coalesce(pc.timezone, 'Africa/Johannesburg'))) as inv,
                   pc.backfill_next, pc.backfill_until, pc.temp_next,
                   public.today_tz(coalesce(pc.timezone, 'Africa/Johannesburg')) as today,
                   coalesce(pc.timezone, 'Africa/Johannesburg') as tz
              from public.plant_config pc where pc.plant_id = p.plant_id) s;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', p.plant_id, 'lastTs', v_ts, 'inverters', v_total, 'online', v_on, 'sync', v_sync));
  end loop;
  return v_out;
end $$;
revoke all on function public.api_plant_states() from public, anon;
grant execute on function public.api_plant_states() to authenticated, service_role;
