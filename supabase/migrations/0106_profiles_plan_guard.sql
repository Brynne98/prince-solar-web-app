-- ============================================================================
-- 0106 — a user can't give themself a paid plan (SOLAR-138 item 3).
--
-- profiles_guard ran BEFORE UPDATE only, and authenticated could DELETE its own
-- row. So a user could delete the row and insert it again with plan = 'pro'.
--
-- Now:
--   - authenticated loses DELETE. Nothing in the app deletes a profile; account
--     deletion (api_account_delete) is security definer and keeps working.
--   - profiles_guard also runs on INSERT: a row a signed-in user inserts must have
--     plan 'free'. api_prefs_set (security invoker) inserts with the default
--     'free', so it still works. handle_new_user runs from the auth.users trigger
--     with no auth.uid(), so it is not checked and still makes the row.
-- ============================================================================

revoke delete on public.profiles from authenticated;

create or replace function public.profiles_guard()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' and auth.uid() is not null and new.plan is distinct from 'free' then
    raise exception 'plan is not user-editable' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and auth.uid() is not null and new.plan is distinct from old.plan then
    raise exception 'plan is not user-editable' using errcode = '42501';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before insert or update on public.profiles
  for each row execute function public.profiles_guard();
