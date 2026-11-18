-- 0222 — no "shared plant stopped / is back" to an account its plant is not read for
-- (SOLAR-582, decided by Brynne 2026-11-18: an account with no plan gets only the
-- win-back emails). share_down and share_back are not in is_alert (they stay out of
-- the app's alert list), so 0206's unread-plant gate let them through. Same trigger,
-- one kind list added.

create or replace function private.email_skip_paused()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.plant_id is not null and exists (select 1 from public.plant_users pu
       where pu.user_id = new.user_id and pu.plant_id = new.plant_id and pu.paused) then
    return null;
  end if;
  -- No plan: no report but the free week's last one (0114), in the week too.
  if new.kind like 'report\_%' and not coalesce((new.data->>'freeWeekEnds')::boolean, false)
     and coalesce((select b.plan from private.billing b where b.user_id = new.user_id), 'free') = 'free' then
    return null;
  end if;
  -- An alert, or a shared plant's stopped/back, for a plant that is not read for this account.
  if new.plant_id is not null and new.user_id is not null
     and (private.is_alert(new.kind) or new.kind in ('share_down', 'share_back'))
     and not private.plant_live(new.user_id, new.plant_id) then
    return null;
  end if;
  return new;
end $$;
