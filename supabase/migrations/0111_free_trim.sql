-- ============================================================================
-- 0111 — Free keeps 24 hours after its first week (SOLAR-208).
--
-- A plant is trimmed when every account that sees it is on Free and that
-- account's free week (its first private.free_week_logins row, 0110) started more
-- than 7 days ago. A plant shared with a paying account keeps everything. An
-- account with no free week on record (everyone from before 0110) is never trimmed.
--
-- free_trim runs hourly and deletes a trimmed plant's readings older than 24 hours:
-- minutes, 5-minute rows, strings, inverter history, grid-off spans that ended, and
-- day totals before yesterday (month totals all go). Settings, logins and alerts
-- stay. It also clears the plant's history-import bookmarks, and recover and
-- sync-plant-energy skip the old days (free_trimmed_plants), so nothing fetches back
-- what the trim deletes.
--
-- Cost: a plant's first trim deletes everything old. After that a run deletes only
-- from an hour before the previous run's cutoff, a short range on each ts index, so
-- a missed run is caught up by the next. private.free_trim_done holds each plant's
-- last trim; a plant that leaves (upgrade, shared with a payer) is unmarked, so
-- coming back trims it in full. recover only refills today for these plants, which
-- is never older than the cutoff by more than the band.
-- ============================================================================

create or replace function public.free_trimmed_plants()
returns setof bigint
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select pu.plant_id
    from public.plant_users pu
    left join private.billing b on b.user_id = pu.user_id
    left join lateral (select min(started_at) as started from private.free_week_logins f
                        where f.user_id = pu.user_id) fw on true
   group by pu.plant_id
  having bool_and(coalesce(b.plan, 'free') = 'free' and fw.started is not null
                  and fw.started < now() - interval '7 days')
$$;
revoke all on function public.free_trimmed_plants() from public, anon, authenticated;
grant execute on function public.free_trimmed_plants() to service_role;

create table if not exists private.free_trim_done (
  plant_id  bigint primary key,
  at        timestamptz not null default now()
);
revoke all on table private.free_trim_done from public, anon, authenticated;

create or replace function private.free_trim()
returns jsonb
language plpgsql security definer set search_path = public, private, pg_temp
as $$
declare
  cut bigint := extract(epoch from now() - interval '24 hours')::bigint;
  lo bigint;
  last timestamptz;
  p bigint;
  n bigint;
  total bigint := 0;
  plants int := 0;
begin
  delete from private.free_trim_done d where d.plant_id not in (select public.free_trimmed_plants());
  for p in select public.free_trimmed_plants() loop
    plants := plants + 1;
    -- First trim: everything old. Then: the hours that just passed the cutoff.
    select at into last from private.free_trim_done where plant_id = p;
    lo := case when last is null then 0 else extract(epoch from last - interval '25 hours')::bigint end;
    delete from public.readings            where plant_id = p and ts >= lo and ts < cut; get diagnostics n = row_count; total := total + n;
    delete from public.strings             where plant_id = p and ts >= lo and ts < cut; get diagnostics n = row_count; total := total + n;
    delete from public.readings_5m         where plant_id = p and ts >= lo and ts < cut; get diagnostics n = row_count; total := total + n;
    delete from public.strings_5m          where plant_id = p and ts >= lo and ts < cut; get diagnostics n = row_count; total := total + n;
    delete from public.agg_minute          where plant_id = p and ts >= lo and ts < cut; get diagnostics n = row_count; total := total + n;
    delete from public.agg_5m              where plant_id = p and ts >= lo and ts < cut; get diagnostics n = row_count; total := total + n;
    delete from public.inverter_history    where plant_id = p and ts >= lo and ts < cut; get diagnostics n = row_count; total := total + n;
    delete from public.inverter_history_5m where plant_id = p and ts >= lo and ts < cut; get diagnostics n = row_count; total := total + n;
    delete from public.grid_off            where plant_id = p and ended_at < to_timestamp(cut); get diagnostics n = row_count; total := total + n;
    delete from public.plant_energy e
     where e.plant_id = p
       and (e.bucket = 'month'
            or e.period < public.today_tz(coalesce((select timezone from public.plant_config where plant_id = p), 'Africa/Johannesburg')) - 1);
    get diagnostics n = row_count; total := total + n;
    update public.plant_config
       set backfill_next = null, backfill_until = null, temp_next = null
     where plant_id = p and (backfill_next is not null or temp_next is not null);
    insert into private.free_trim_done (plant_id) values (p) on conflict (plant_id) do update set at = now();
  end loop;
  return jsonb_build_object('plants', plants, 'rows', total);
end $$;
revoke all on function private.free_trim() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping jobs (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'free-trim') then
    perform cron.unschedule('free-trim');
  end if;
  perform cron.schedule('free-trim', '20 * * * *', 'select private.free_trim()');
end $$;
