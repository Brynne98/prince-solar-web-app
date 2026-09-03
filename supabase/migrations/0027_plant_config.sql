-- ============================================================================
-- 0027 — per-plant configuration, per-user profile, provider on accounts.
--
-- Until now every site-specific number lived in the single-row public.app_config:
-- battery size, reserve, nameplate, coordinates, roof geometry. With more than one
-- plant that is wrong for everyone but the first. This migration:
--
--   1. public.plant_config — one row per plant. Timezone and currency come from the
--      SunSynk API at link time (it reports both, as IANA zone and ISO code); so do
--      lat, lon and nameplate kWp. Battery size, reserve, tariff and roof geometry
--      are the user's to set in Settings. The existing plant is seeded from
--      app_config so nothing changes for it.
--
--   2. public.profiles — one row per dashboard user: the plan flag (free now, paid
--      later without a migration) and display preferences that used to sit in
--      localStorage and so vanished on a new device.
--
--   3. private.sunsynk_accounts.provider — which cloud this login is for. Only
--      'sunsynk' exists today; the column is here so a second vendor is a value,
--      not a schema change.
--
-- app_config stays for the deployment-wide solar model constants (DNI base, the
-- calibration percentile and cap) and as the fallback the calibration plant reads.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. plant_config
-- ---------------------------------------------------------------------------
create table if not exists public.plant_config (
  plant_id            bigint primary key,
  -- from the API at link time; editable
  timezone            text not null default 'Africa/Johannesburg',
  currency            text not null default 'ZAR' check (currency ~ '^[A-Z]{3}$'),
  lat                 double precision,
  lon                 double precision,
  system_kwp          double precision,
  -- the user's numbers
  tariff_import       double precision not null default 0,   -- per kWh, in `currency`
  battery_kwh         double precision,
  battery_reserve_pct double precision not null default 20 check (battery_reserve_pct between 0 and 100),
  -- roof geometry: defaults are hemisphere-aware until the fitting feature exists.
  -- azimuth is compass degrees from north; 0 = north-facing (southern hemisphere),
  -- 180 = south-facing (northern hemisphere).
  panel_tilt          double precision not null default 15,
  panel_azimuth       double precision not null default 0,
  geometry_source     text not null default 'default'
                      check (geometry_source in ('default', 'user', 'fitted', 'seeded')),
  updated_at          timestamptz not null default now(),
  updated_by          uuid references auth.users (id) on delete set null
);

alter table public.plant_config enable row level security;
drop policy if exists plant_config_read on public.plant_config;
create policy plant_config_read on public.plant_config
  for select to authenticated using (plant_id in (select public.my_plant_ids()));
drop policy if exists plant_config_write on public.plant_config;
create policy plant_config_write on public.plant_config
  for update to authenticated
  using (plant_id in (select public.my_plant_ids()))
  with check (plant_id in (select public.my_plant_ids()));
revoke all on public.plant_config from anon;
grant select, update on public.plant_config to authenticated;
grant select, insert, update, delete on public.plant_config to service_role;

-- Seed the existing plant from app_config so today's numbers carry over exactly.
insert into public.plant_config
  (plant_id, timezone, currency, lat, lon, system_kwp, tariff_import,
   battery_kwh, battery_reserve_pct, panel_tilt, panel_azimuth, geometry_source)
select pu.plant_id,
       'Africa/Johannesburg', 'ZAR',
       public.cfg('LAT'), public.cfg('LON'), public.cfg('SYSTEM_KWP'),
       3.40,                                  -- the frontend's old default import rate
       public.cfg('BATTERY_KWH'), coalesce(public.cfg('BATTERY_RESERVE_PCT'), 20),
       coalesce(public.cfg('PANEL_TILT'), 15), coalesce(public.cfg('PANEL_AZIMUTH'), 0),
       'seeded'
  from (select distinct plant_id from public.plant_users) pu
on conflict (plant_id) do nothing;

-- Keep updated_at honest.
create or replace function public.plant_config_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end $$;
drop trigger if exists plant_config_touch on public.plant_config;
create trigger plant_config_touch before update on public.plant_config
  for each row execute function public.plant_config_touch();

-- ---------------------------------------------------------------------------
-- 2. profiles
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  plan        text not null default 'free' check (plan in ('free', 'pro')),
  -- display preferences that follow the user: batt sign convention, tab choices,
  -- last-selected plant. Free-form so the frontend can add keys without migrations.
  prefs       jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.profiles enable row level security;
drop policy if exists profiles_own on public.profiles;
create policy profiles_own on public.profiles
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.profiles from anon;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.profiles to service_role;

-- A profile exists for every user, created on first sign-up. plan is not writable
-- by the user: the policy allows the row, this trigger pins the column.
create or replace function public.profiles_guard()
returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and auth.uid() is not null and new.plan is distinct from old.plan then
    raise exception 'plan is not user-editable' using errcode = '42501';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.profiles_guard();

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.profiles (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill for users who already exist.
insert into public.profiles (user_id) select id from auth.users on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 3. provider on accounts
-- ---------------------------------------------------------------------------
alter table private.sunsynk_accounts
  add column if not exists provider text not null default 'sunsynk'
  check (provider in ('sunsynk'));

-- ---------------------------------------------------------------------------
-- 4. Accessors
-- ---------------------------------------------------------------------------
-- Everything a function needs about a plant, in one row. Falls back to app_config
-- for plants that somehow have no row, so nothing divides by null.
create or replace function public.plant_cfg(p_plant bigint)
returns table (timezone text, currency text, lat double precision, lon double precision,
               system_kwp double precision, tariff_import double precision,
               battery_kwh double precision, battery_reserve_pct double precision,
               panel_tilt double precision, panel_azimuth double precision, geometry_source text)
language sql stable
set search_path = public, pg_temp
as $$
  select coalesce(c.timezone, 'Africa/Johannesburg'),
         coalesce(c.currency, 'ZAR'),
         coalesce(c.lat, public.cfg('LAT')), coalesce(c.lon, public.cfg('LON')),
         coalesce(c.system_kwp, public.cfg('SYSTEM_KWP')),
         coalesce(c.tariff_import, 0),
         coalesce(c.battery_kwh, public.cfg('BATTERY_KWH')),
         coalesce(c.battery_reserve_pct, public.cfg('BATTERY_RESERVE_PCT'), 20),
         coalesce(c.panel_tilt, public.cfg('PANEL_TILT'), 15),
         coalesce(c.panel_azimuth, public.cfg('PANEL_AZIMUTH'), 0),
         coalesce(c.geometry_source, 'default')
    from (select p_plant as id) x
    left join public.plant_config c on c.plant_id = x.id
$$;
revoke all on function public.plant_cfg(bigint) from public, anon;
grant execute on function public.plant_cfg(bigint) to authenticated, service_role;

-- Called by the link function after plants are discovered. Creates the row with
-- what the API knows; never overwrites a row the user may have edited.
create or replace function public.plant_config_seed(p_rows jsonb)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.plant_config (plant_id, timezone, currency, lat, lon, system_kwp, panel_azimuth, geometry_source)
  select (r->>'plant_id')::bigint,
         coalesce(nullif(r->>'timezone', ''), 'Africa/Johannesburg'),
         coalesce(nullif(upper(r->>'currency'), ''), 'ZAR'),
         nullif(r->>'lat', '')::double precision,
         nullif(r->>'lon', '')::double precision,
         nullif(r->>'system_kwp', '')::double precision,
         -- north-facing south of the equator, south-facing north of it
         case when nullif(r->>'lat', '')::double precision > 0 then 180 else 0 end,
         'default'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id) do nothing
$$;
revoke all on function public.plant_config_seed(jsonb) from public, anon, authenticated;
grant execute on function public.plant_config_seed(jsonb) to service_role;

-- The user's own settings, for the frontend: profile + every plant they can see,
-- with config. One call on load.
create or replace function public.api_me()
returns jsonb
language sql stable
security invoker
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'user', jsonb_build_object('id', auth.uid()),
    'plan', coalesce((select plan from public.profiles where user_id = auth.uid()), 'free'),
    'prefs', coalesce((select prefs from public.profiles where user_id = auth.uid()), '{}'::jsonb),
    'plants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pu.plant_id, 'name', pu.plant_name,
               'config', to_jsonb(c) - 'plant_id' - 'updated_by')
             order by pu.linked_at, pu.plant_id)
        from public.plant_users pu
        left join public.plant_config c on c.plant_id = pu.plant_id
       where pu.user_id = auth.uid()), '[]'::jsonb))
$$;
revoke all on function public.api_me() from public, anon;
grant execute on function public.api_me() to authenticated, service_role;

-- Save preferences: shallow-merged so the frontend can update one key.
create or replace function public.api_prefs_set(p_prefs jsonb)
returns jsonb
language sql
security invoker
set search_path = public, pg_temp
as $$
  insert into public.profiles (user_id, prefs) values (auth.uid(), coalesce(p_prefs, '{}'::jsonb))
  on conflict (user_id) do update set prefs = public.profiles.prefs || excluded.prefs
  returning prefs
$$;
revoke all on function public.api_prefs_set(jsonb) from public, anon;
grant execute on function public.api_prefs_set(jsonb) to authenticated;
