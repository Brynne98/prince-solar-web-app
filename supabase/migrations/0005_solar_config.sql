-- ============================================================================
-- Solar model configuration.
--
-- server.js reads these from environment variables, so the deployed values are
-- whatever .env says — not the code defaults. Hardcoding the defaults into
-- clear_sky_shape() produced a visibly wrong potential curve (PANEL_AZIMUTH is 340
-- here, not 0; SOLAR_DNI_BASE is 0.72, not 0.82), so they live in a table instead.
--
-- Seeded to match .env as of this migration. If you change .env, change this too —
-- they are the same physical system described twice.
-- ============================================================================

create table if not exists public.app_config (
  key   text primary key,
  value double precision not null,
  note  text
);

insert into public.app_config (key, value, note) values
  ('LAT',                  -26.2041, 'latitude for sun geometry'),
  ('PANEL_TILT',                 25, 'degrees from horizontal'),
  ('PANEL_AZIMUTH',             340, 'compass deg from North (0 = due north)'),
  ('SOLAR_DNI_BASE',           0.72, 'clear-sky beam attenuation base'),
  ('SYSTEM_KWP',               12.6, 'nameplate kWp (calibration ceiling)'),
  ('SOLAR_CAL_PERCENTILE',     0.95, 'calibration percentile'),
  ('SOLAR_CAL_CAP_MULT',        1.5, 'ceiling multiple of nameplate kWp')
on conflict (key) do update set value = excluded.value, note = excluded.note;

create or replace function public.cfg(p_key text)
returns double precision language sql stable parallel safe as $$
  select value from public.app_config where key = p_key
$$;

-- ---------------------------------------------------------------------------
-- Re-create the solar model reading config instead of literals. STABLE rather
-- than IMMUTABLE now that it touches a table — nothing indexes on it, so the only
-- cost is losing an optimisation we never used.
-- ---------------------------------------------------------------------------
create or replace function public.clear_sky_shape(p_ts bigint)
returns double precision language sql stable parallel safe as $$
  with c as (
    select public.cfg('LAT') as lat, public.cfg('PANEL_TILT') as tilt,
           public.cfg('PANEL_AZIMUTH') as azimuth, public.cfg('SOLAR_DNI_BASE') as dni_base,
           public.local_ts(p_ts) as d
  ),
  g as (
    select radians(23.45 * sin(radians(360 * (284 + extract(doy from d)::int) / 365.0))) as decl,
           radians(15 * ((extract(hour from d) * 60 + extract(minute from d)) / 60.0 - 12)) as w,
           radians(lat) as phi, radians(tilt) as b, radians(azimuth) as gz, dni_base
      from c
  ),
  s as (
    select -cos(decl) * sin(w) as se,
           cos(phi) * sin(decl) - sin(phi) * cos(decl) * cos(w) as sn,
           sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(w) as su,
           sin(b) * sin(gz) as ne, sin(b) * cos(gz) as nn, cos(b) as nu, dni_base
      from g
  )
  select case when su <= 0 then 0  -- sun below horizon
              else power(dni_base, power(1 / greatest(0.05, su), 0.678))  -- air-mass attenuation
                   * greatest(0, se * ne + sn * nn + su * nu)
         end
    from s
$$;

create or replace function public.solar_scale_w()
returns integer language sql stable as $$
  with ratios as (
    select c.pv_w / public.clear_sky_shape(c.ts) as r
      from public.q_cal_samples() c
     where public.clear_sky_shape(c.ts) > 0.25
  ),
  n as (select count(*) as c from ratios),
  picked as (
    select r from ratios, n
     where n.c >= 20
     order by r offset (select floor(c * public.cfg('SOLAR_CAL_PERCENTILE'))::int from n) limit 1
  )
  -- fallback until there's enough data, then cap at CAP_MULT x nameplate
  select round(least(
           coalesce((select r from picked), public.cfg('SYSTEM_KWP') * 1000 * 0.82),
           public.cfg('SYSTEM_KWP') * 1000 * public.cfg('SOLAR_CAL_CAP_MULT')))::int
$$;

-- config is readable by the dashboard, writable by nobody through the API
alter table public.app_config enable row level security;
drop policy if exists app_config_read on public.app_config;
create policy app_config_read on public.app_config for select to authenticated using (true);
revoke all on public.app_config from anon;
grant select on public.app_config to authenticated, service_role;

revoke all on function public.cfg(text) from public, anon;
grant execute on function public.cfg(text) to authenticated, service_role;
