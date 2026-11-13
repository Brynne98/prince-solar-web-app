-- ============================================================================
-- 0200 — third cheating review, findings M1, M2 and M3 (SOLAR-548).
--
-- M1. Before: an account whose payment has failed (state past_due) and that has a
-- place open could link a second SunSynk login with one plant, or claim a shared
-- plant. The plant got a tick, started, and got a 60-day fetch. 0198 refused the
-- owner's own tick and change in that state, and left these two paths.
-- Now: private.plant_pick_add gives no new tick in past_due, so the plant links
-- locked, as it does when no place is open. A plant that already has a tick is not
-- affected. Paying sets the state back to active, and the owner's tick, a link and
-- a claim work again. A payment that starts plants (billing_resume) runs after the
-- state is active.
--
-- M2. Before: 0199 wrote the account's free-week row for Free accounts only. A paid
-- account from before 0199 with no row kept its weekly, monthly and yearly reports
-- after a drop to Free (the hold-back in 0114 needs the row).
-- Now: every account that has a plant and no row gets one, dated 15 days back, the
-- date 0199 gives an account that joins after the week. That is past the week (7
-- days) and past the "ended" notice (day 7 to 14), and the emails go only on their
-- own day (2, 5, 7): no free week, no notice and no email.
--
-- M3. Before: the free week went by the plant number only (0199). A new plant made
-- in the SunSynk app, with the logger moved to it, had no week on record: a new
-- account got a new week and a new 60-day fetch.
-- Now: private.inverter_week keeps the serial number of each inverter of a plant
-- whose week has started, with that week's start. Serial and date, nothing else. It
-- stays after an account delete and a plant purge.
-- The link call does not know the serials. Every path stores them after it through
-- inverters_seed: the link, a share claim, and each poll (poll_commit). So the check
-- is a trigger on private.inverters, in the same transaction as the serial write:
--   - a serial that is on record with an earlier week moves the plant's week back
--     to that date. Reads, the trim and the fetch go by the plant's week (0199), so
--     they follow. The 60-day bookmarks are dropped when the plant is then on the
--     trim list, as plant_start_fill does (0174).
--   - the account row the link wrote from this plant's week moves back too, by
--     0199's rule (at least 15 days back when the week is over): no free-week card,
--     notice or email.
--   - then the plant's serials go on record with the plant's week.
-- A plant with no week (only paid accounts hold it) writes no record. When its week
-- starts later, a trigger on private.plant_week runs the same check.
-- recover walks no plant that has no serials, and the serial write and the check
-- are one transaction: the fetch cannot start on a plant before its check.
-- A second inverter on a plant, or a replaced one, goes on record with the plant's
-- week and changes nothing. Known limit: an inverter bought second-hand, whose
-- serial had its week under another owner, brings no new week.
-- ============================================================================

-- 0197's body with the state check.
create or replace function private.plant_pick_add(p_user uuid, p_plant bigint, p_name text)
returns boolean language plpgsql set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if exists (select 1 from private.plant_picks where user_id = p_user and plant_id = p_plant) then return true; end if;
  select * into b from private.billing where user_id = p_user;
  if b.state = 'past_due' then return false; end if;  -- no new tick until the payment
  if not coalesce(b.comped, false)
     and (select count(*) from private.plant_picks where user_id = p_user) >= public.billing_room(b.plan, b.extra_plants) then
    return false;
  end if;
  insert into private.plant_picks (user_id, plant_id, plant_name) values (p_user, p_plant, p_name);
  return true;
end $$;
revoke all on function private.plant_pick_add(uuid, bigint, text) from public, anon, authenticated;

insert into private.free_week_logins (sunsynk_username, user_id, started_at)
select '', pu.user_id, now() - interval '15 days'
  from public.plant_users pu
 group by pu.user_id
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------------------
-- M3: the free week also goes by the inverter serial number.
-- ---------------------------------------------------------------------------
create table if not exists private.inverter_week (
  sn         text primary key,
  started_at timestamptz not null
);
alter table private.inverter_week enable row level security;
revoke all on table private.inverter_week from public, anon, authenticated;
grant all on table private.inverter_week to service_role;

insert into private.inverter_week (sn, started_at)
select i.sn, w.started_at
  from private.inverters i
  join private.plant_week w on w.plant_id = i.plant_id
on conflict (sn) do nothing;

-- For private.inverters (a serial stored or moved) and private.plant_week (a week
-- started): both rows carry plant_id.
create or replace function private.week_by_serial()
returns trigger language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  p bigint := new.plant_id;
  wk timestamptz;
  rec timestamptz;
begin
  select started_at into wk from private.plant_week where plant_id = p;
  if wk is null then return null; end if;
  select min(r.started_at) into rec
    from private.inverter_week r join private.inverters i on i.sn = r.sn
   where i.plant_id = p;
  if rec < wk then
    update private.plant_week set started_at = rec where plant_id = p;
    update private.free_week_logins f
       set started_at = case when rec > now() - interval '7 days' then rec
                             else least(rec, now() - interval '15 days') end
     where f.started_at = wk
       and exists (select 1 from public.plant_users pu where pu.user_id = f.user_id and pu.plant_id = p);
    if p in (select public.free_trimmed_plants()) then
      update public.plant_config set backfill_next = null, backfill_until = null, temp_next = null
       where plant_id = p;
    end if;
    wk := rec;
  end if;
  insert into private.inverter_week (sn, started_at)
  select i.sn, wk from private.inverters i where i.plant_id = p
  on conflict (sn) do nothing;
  return null;
end $$;
revoke all on function private.week_by_serial() from public, anon, authenticated;

drop trigger if exists inverter_week_new on private.inverters;
create trigger inverter_week_new after insert on private.inverters
  for each row execute function private.week_by_serial();
-- each poll writes the same row again: only a move to another plant is checked
drop trigger if exists inverter_week_moved on private.inverters;
create trigger inverter_week_moved after update of plant_id on private.inverters
  for each row when (old.plant_id is distinct from new.plant_id) execute function private.week_by_serial();
drop trigger if exists plant_week_serials on private.plant_week;
create trigger plant_week_serials after insert on private.plant_week
  for each row execute function private.week_by_serial();
