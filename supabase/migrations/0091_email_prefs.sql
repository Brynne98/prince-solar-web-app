-- ============================================================================
-- 0091 — which report and alert emails each user wants (SOLAR-158).
--
-- One row per user, every email on by default; no row reads as all on, so a user
-- who never opened Notifications needs nothing written. Reports: weekly, monthly,
-- yearly. Alerts by group: grid (down, back), battery (hot, uneven charging),
-- panels (stopped producing), readings (none, back), sunsynk (down, back).
-- "SunSynk disconnected" and the account emails have no switch: always sent.
--
-- unsub_token is the secret in each email's List-Unsubscribe link (RFC 8058). The
-- unsubscribe Edge Function posts it with the email's kind; whoever holds it can
-- only turn that user's emails off. A user can't set or change it.
--
-- For senders (service role):
--   public.email_wanted(user_id, kind) → boolean: check before sending.
--   public.email_unsub_token(user_id)  → uuid: for the List-Unsubscribe link,
--     https://<project>.supabase.co/functions/v1/unsubscribe?t=<token>&k=<kind>
-- ============================================================================

create table if not exists public.email_prefs (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  weekly      boolean not null default true,
  monthly     boolean not null default true,
  yearly      boolean not null default true,
  grid        boolean not null default true,
  battery     boolean not null default true,
  panels      boolean not null default true,
  readings    boolean not null default true,
  sunsynk     boolean not null default true,
  unsub_token uuid not null unique default gen_random_uuid(),
  updated_at  timestamptz not null default now()
);

alter table public.email_prefs enable row level security;
drop policy if exists email_prefs_own on public.email_prefs;
create policy email_prefs_own on public.email_prefs
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
revoke all on public.email_prefs from anon, authenticated;
-- Column grants keep unsub_token and updated_at out of the user's hands.
grant select (user_id, weekly, monthly, yearly, grid, battery, panels, readings, sunsynk)
  on public.email_prefs to authenticated;
grant insert (user_id, weekly, monthly, yearly, grid, battery, panels, readings, sunsynk)
  on public.email_prefs to authenticated;
-- user_id too: an upsert sets every column it sends; the policy pins it to the caller.
grant update (user_id, weekly, monthly, yearly, grid, battery, panels, readings, sunsynk)
  on public.email_prefs to authenticated;
grant select, insert, update, delete on public.email_prefs to service_role;

create or replace function public.email_prefs_touch()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists email_prefs_touch on public.email_prefs;
create trigger email_prefs_touch before update on public.email_prefs
  for each row execute function public.email_prefs_touch();

-- True when the user wants this kind of email. Unknown kinds raise, so a typo in a
-- sender fails loudly instead of sending or dropping mail.
create or replace function public.email_wanted(p_user uuid, p_kind text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare r public.email_prefs;
begin
  if p_kind not in ('weekly','monthly','yearly','grid','battery','panels','readings','sunsynk') then
    raise exception 'unknown email kind: %', p_kind;
  end if;
  select * into r from public.email_prefs where user_id = p_user;
  if not found then return true; end if;
  return case p_kind
    when 'weekly' then r.weekly     when 'monthly' then r.monthly   when 'yearly' then r.yearly
    when 'grid' then r.grid         when 'battery' then r.battery   when 'panels' then r.panels
    when 'readings' then r.readings when 'sunsynk' then r.sunsynk end;
end $$;

-- The user's unsubscribe token, making their row (all on) if they have none.
create or replace function public.email_unsub_token(p_user uuid)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
begin
  insert into public.email_prefs (user_id) values (p_user) on conflict (user_id) do nothing;
  return (select unsub_token from public.email_prefs where user_id = p_user);
end $$;

-- One-click unsubscribe: turns one kind off for the token's user. False when the
-- token or kind matches nothing.
create or replace function public.email_unsubscribe(p_token uuid, p_kind text)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_kind not in ('weekly','monthly','yearly','grid','battery','panels','readings','sunsynk') then
    return false;
  end if;
  update public.email_prefs set
    weekly   = weekly   and p_kind <> 'weekly',
    monthly  = monthly  and p_kind <> 'monthly',
    yearly   = yearly   and p_kind <> 'yearly',
    grid     = grid     and p_kind <> 'grid',
    battery  = battery  and p_kind <> 'battery',
    panels   = panels   and p_kind <> 'panels',
    readings = readings and p_kind <> 'readings',
    sunsynk  = sunsynk  and p_kind <> 'sunsynk'
  where unsub_token = p_token;
  return found;
end $$;

revoke all on function public.email_wanted(uuid, text) from public, anon, authenticated;
revoke all on function public.email_unsub_token(uuid) from public, anon, authenticated;
revoke all on function public.email_unsubscribe(uuid, text) from public, anon, authenticated;
grant execute on function public.email_wanted(uuid, text) to service_role;
grant execute on function public.email_unsub_token(uuid) to service_role;
grant execute on function public.email_unsubscribe(uuid, text) to service_role;

notify pgrst, 'reload schema';
