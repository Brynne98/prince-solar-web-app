-- ============================================================================
-- 0125 — the user picks which plants collect (SOLAR-251, decided 2026-10-30).
--
-- A plant collects or is stopped (plant_users.paused, 0110). The plan sets how
-- many collect: Free and Home 1, Family 3 (more at R49 an inverter, through the
-- paywall). To collect another plant the user stops one first, or upgrades.
--   - api_plant_stop: the plant stops collecting for this user. When no other
--     account still collects it, all its readings are deleted. Settings, logins,
--     inverters and alerts stay, so the plant can start again.
--   - api_plant_start: the plant collects again, if the plan has room. History is
--     pulled the way a new link pulls it: 60 days on a paid plan or in the free
--     week, today only on Free past its week (0111).
-- Cancelling a paid plan is still refused while too many plants collect; the user
-- stops plants first (api_billing_change, 0110).
--
-- plant_row_guard now drops readings for a plant that nobody collects, so a
-- history walk (recover) still running when the plant stops can't write it back.
-- Inverters, config and meta still land: a stopped plant keeps those.
-- ============================================================================

create or replace function private.plant_row_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.plant_id is null then return new; end if;
  if pg_try_advisory_xact_lock_shared(new.plant_id)
     and exists (select 1 from public.plant_users pu where pu.plant_id = new.plant_id
                  and (not pu.paused or tg_table_name in ('inverters', 'plant_config', 'meta'))) then
    return new;
  end if;
  return null;
end $$;

-- Every reading a plant has. Under the plant's lock, so an in-flight writer
-- finishes first and a late one is dropped by the guard.
create or replace function private.plant_wipe_readings(p_plant bigint)
returns bigint
language plpgsql
set search_path = public, private, pg_temp
as $$
declare n bigint; total bigint := 0;
begin
  perform pg_advisory_xact_lock(p_plant);
  delete from public.readings            where plant_id = p_plant; get diagnostics n = row_count; total := total + n;
  delete from public.strings             where plant_id = p_plant; get diagnostics n = row_count; total := total + n;
  delete from public.readings_5m         where plant_id = p_plant; get diagnostics n = row_count; total := total + n;
  delete from public.strings_5m          where plant_id = p_plant; get diagnostics n = row_count; total := total + n;
  delete from public.agg_minute          where plant_id = p_plant; get diagnostics n = row_count; total := total + n;
  delete from public.agg_5m              where plant_id = p_plant; get diagnostics n = row_count; total := total + n;
  delete from public.plant_energy        where plant_id = p_plant; get diagnostics n = row_count; total := total + n;
  delete from public.inverter_history    where plant_id = p_plant; get diagnostics n = row_count; total := total + n;
  delete from public.inverter_history_5m where plant_id = p_plant; get diagnostics n = row_count; total := total + n;
  delete from public.grid_off            where plant_id = p_plant; get diagnostics n = row_count; total := total + n;
  delete from private.gaps               where plant_id = p_plant;
  delete from private.grid_off_progress  where plant_id = p_plant;
  delete from private.free_trim_done     where plant_id = p_plant;
  update public.plant_config
     set backfill_next = null, backfill_until = null, backfill_tries = 0, temp_next = null
   where plant_id = p_plant;
  return total;
end $$;
revoke all on function private.plant_wipe_readings(bigint) from public, anon, authenticated;

-- A plant that starts collecting pulls history the way a new link does: 60 days,
-- or none on Free past its week (0111). Then recover, sync-plant-energy and a
-- poll are kicked for it (0094).
create or replace function private.plant_start_fill(p_plant bigint)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare tz text;
begin
  if not exists (select 1 from public.plant_config where plant_id = p_plant) then
    -- Linked stopped, so never seeded (sunsynk.ts syncPlants). South Africa only;
    -- the seed sets the 60-day bookmarks.
    perform public.plant_config_seed(jsonb_build_array(jsonb_build_object('plant_id', p_plant)));
  else
    select coalesce(timezone, 'Africa/Johannesburg') into tz from public.plant_config where plant_id = p_plant;
    update public.plant_config
       set backfill_next = (now() at time zone tz)::date - 60,
           backfill_until = (now() at time zone tz)::date - 14,
           backfill_tries = 0,
           temp_next = (now() at time zone tz)::date - 60
     where plant_id = p_plant;
  end if;
  if p_plant in (select public.free_trimmed_plants()) then
    update public.plant_config set backfill_next = null, backfill_until = null, temp_next = null
     where plant_id = p_plant;
  end if;
  perform public.plant_bootstrap_kick(p_plant);
end $$;
revoke all on function private.plant_start_fill(bigint) from public, anon, authenticated;

create or replace function public.api_plant_stop(p_plant bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare rows bigint := 0;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  update public.plant_users set paused = true
   where user_id = auth.uid() and plant_id = p_plant and not paused;
  if not found then
    if not exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = p_plant) then
      raise exception 'plant % is not linked to this user', p_plant using errcode = '42501';
    end if;
    return jsonb_build_object('stopped', true, 'rows', 0);
  end if;
  -- A plant someone else still collects keeps its readings: they are theirs too.
  if not exists (select 1 from public.plant_users where plant_id = p_plant and not paused) then
    rows := private.plant_wipe_readings(p_plant);
  end if;
  return jsonb_build_object('stopped', true, 'rows', rows);
end $$;

-- 'no_room' when the plan is full (the app offers the upgrade), 'plan_change'
-- when a booked downgrade or cancel would have too many plants.
create or replace function public.api_plant_start(p_plant bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  b private.billing;
  active int;
  others boolean;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if not exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = p_plant) then
    raise exception 'plant % is not linked to this user', p_plant using errcode = '42501';
  end if;
  select * into b from private.billing where user_id = auth.uid() for update;
  if not exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = p_plant and paused) then
    return jsonb_build_object('started', true);
  end if;
  active := (select count(*) from public.plant_users where user_id = auth.uid() and not paused);
  -- Family's 4th plant costs R49 an inverter: that goes through the paywall.
  if active >= coalesce(public.billing_plant_limit(coalesce(b.plan, 'free')), 3) then
    raise exception 'no room' using errcode = '22023';
  end if;
  if b.next_plan is not null and active >= coalesce(public.billing_plant_limit(b.next_plan), 2147483647) then
    raise exception 'plan change' using errcode = '22023';
  end if;
  others := exists (select 1 from public.plant_users where plant_id = p_plant and not paused);
  update public.plant_users set paused = false where user_id = auth.uid() and plant_id = p_plant;
  -- Someone else collects it: its readings are there already.
  if not others then perform private.plant_start_fill(p_plant); end if;
  return jsonb_build_object('started', true);
end $$;

do $$
declare f text;
begin
  foreach f in array array['api_plant_stop(bigint)', 'api_plant_start(bigint)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

-- An upgrade resumes stopped plants (0116): they pull history too now.
create or replace function private.billing_resume(p_user uuid, p_plan text, p_added int)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  active int := (select count(*) from public.plant_users where user_id = p_user and not paused);
  room int := p_added;
  resumed bigint[] := '{}';
  r record;
  others boolean;
begin
  for r in select pu.plant_id, (select count(*) from private.inverters i where i.plant_id = pu.plant_id)::int as inv
             from public.plant_users pu
            where pu.user_id = p_user and pu.paused
            order by pu.linked_at, pu.plant_id loop
    if active < coalesce(public.billing_plant_limit(p_plan), 3) then
      null;
    elsif p_plan = 'family' and r.inv <= room then
      room := room - r.inv;
    else
      exit;
    end if;
    others := exists (select 1 from public.plant_users where plant_id = r.plant_id and not paused);
    update public.plant_users set paused = false where user_id = p_user and plant_id = r.plant_id;
    if not others then perform private.plant_start_fill(r.plant_id); end if;
    active := active + 1;
    resumed := resumed || r.plant_id;
  end loop;
  -- A plant stopped by a move to Free and now resumed is no longer up for deletion;
  -- the ones still paused stay booked.
  update private.billing
     set plants_to_remove = array(select x from unnest(plants_to_remove) x where x <> all (resumed)),
         remove_on = case when plants_to_remove <@ resumed then null else remove_on end
   where user_id = p_user and plants_to_remove && resumed;
end $$;
