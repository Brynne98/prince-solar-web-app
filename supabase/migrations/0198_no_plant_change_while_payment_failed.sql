-- ============================================================================
-- 0198 — no plant change and no new tick while a payment has failed (SOLAR-546,
--        decided by Brynne 2026-11-13: "no changes until payment").
--
-- Before: an owner whose card failed (state past_due, the 8 days of retries) could
-- still swap which plant runs, or tick a locked plant into an open place. A plan
-- change in that state is refused (0189).
--
-- Now: api_plant_change and api_plant_pick refuse in past_due with 0189's
-- 'pay the failed payment first'. A past_due account can have an open place (Home
-- with one plant ticked, or a login linked after the card failed), so the tick is
-- refused too. Paying sets the state back to active and both work again.
--
-- Not changed: a payment that starts plants (billing_resume), a share claim, and a
-- new login with one plant. None of them is the owner choosing a plant.
--
-- Both bodies are 0197's with the one check added after the user lock.
-- ============================================================================

-- Tick locked plants into open places. All of them, or none.
create or replace function public.api_plant_pick(p_plants bigint[])
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  uid uuid := auth.uid();
  r record;
  n int := 0;
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(uid);
  if (select state from private.billing where user_id = uid) = 'past_due' then
    raise exception 'pay the failed payment first' using errcode = '22023';
  end if;
  for r in select pu.plant_id, pu.plant_name, pu.paused from public.plant_users pu
            where pu.user_id = uid and pu.plant_id = any (coalesce(p_plants, '{}')) and pu.share_gone_at is null
            order by pu.plant_id loop
    n := n + 1;
    continue when not r.paused;
    if not private.plant_pick_add(uid, r.plant_id, r.plant_name) then
      raise exception 'no room' using errcode = '22023';
    end if;
    perform private.plant_run(uid, r.plant_id);
  end loop;
  if n <> (select count(distinct x) from unnest(coalesce(p_plants, '{}')) x) then
    raise exception 'a plant is not linked to this user' using errcode = '42501';
  end if;
  return public.api_plant_picks();
end $$;

-- One ticked plant out, one locked plant in. Refused inside 90 days of the last
-- change: 'next change <date>'.
create or replace function public.api_plant_change(p_out bigint, p_in bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  uid uuid := auth.uid();
  last date;
  plant_in public.plant_users;
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(uid);
  if (select state from private.billing where user_id = uid) = 'past_due' then
    raise exception 'pay the failed payment first' using errcode = '22023';
  end if;
  select changed_on into last from private.plant_change where user_id = uid;
  if last + 90 > private.billing_today() then
    raise exception 'next change %', to_char(last + 90, 'YYYY-MM-DD') using errcode = '22023';
  end if;
  if p_out is null or p_in is null or p_out = p_in
     or not exists (select 1 from private.plant_picks where user_id = uid and plant_id = p_out) then
    raise exception 'not picked' using errcode = '22023';
  end if;
  select * into plant_in from public.plant_users where user_id = uid and plant_id = p_in and share_gone_at is null;
  if not found then raise exception 'plant % is not linked to this user', p_in using errcode = '42501'; end if;
  if not plant_in.paused then raise exception 'already on' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(least(p_out, p_in));
  perform pg_advisory_xact_lock(greatest(p_out, p_in));

  update public.plant_users set paused = true where user_id = uid and plant_id = p_out and not paused;
  -- A plant someone else still collects keeps its readings; the wipe checks again when it runs (0125).
  if found and not exists (select 1 from public.plant_users where plant_id = p_out and not paused) then
    insert into private.plant_wipe (plant_id) values (p_out) on conflict (plant_id) do nothing;
  end if;
  delete from private.plant_picks where user_id = uid and plant_id = p_out;
  insert into private.plant_picks (user_id, plant_id, plant_name) values (uid, p_in, plant_in.plant_name)
  on conflict do nothing;
  perform private.plant_run(uid, p_in);

  insert into private.plant_change (user_id, changed_on) values (uid, private.billing_today())
  on conflict (user_id) do update set changed_on = excluded.changed_on;
  return public.api_plant_picks();
end $$;
