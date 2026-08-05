-- ============================================================================
-- SunSynk dashboard — Postgres schema, ported from the SQLite schema in db.js.
--
-- Two schemas, and the split is a security boundary, not organisation:
--
--   private  NOT exposed to PostgREST. Holds the SunSynk access/refresh tokens and
--            inverter identifiers. Only the Edge Functions (service_role) touch it.
--   public   Exposed, RLS-protected, authenticated-only. Dashboard data only.
--
-- The dashboard's anon key ships inside a public GitHub Pages bundle, so anything
-- reachable with that key is effectively world-readable. A SunSynk bearer token in
-- an exposed schema would let a stranger act on the account — hence `private`.
-- Tables created via raw SQL do NOT get RLS automatically; every public table below
-- enables it explicitly.
-- ============================================================================

create schema if not exists private;

-- Lock the private schema down. Edge Functions use service_role, which bypasses
-- both RLS and these grants; anon/authenticated must never reach it.
revoke all on schema private from anon, authenticated;

-- ---------------------------------------------------------------------------
-- private — credentials and identifiers
-- ---------------------------------------------------------------------------

-- Replaces the monolith's in-memory `tokenCache`: Edge Functions are stateless
-- across per-minute invocations, so the token needs somewhere durable to live.
create table if not exists private.auth (
  id            int primary key default 1 check (id = 1),
  access_token  text,
  refresh_token text,
  expires_at    bigint
);
insert into private.auth (id) values (1) on conflict do nothing;

-- Inverter serials to poll. server.js discovers these live on every tick; caching
-- them removes a SunSynk round-trip from the hot path.
create table if not exists private.inverters (
  sn       text primary key,
  plant_id bigint
);

-- was: meta (SQLite). Inverter identity/firmware; also carries plant_id/plant_name.
create table if not exists private.meta (
  sn                  text primary key,
  updated_ts          bigint,
  alias               text,
  model               text,
  soft_ver            text,
  hmi_ver             text,
  gsn                 text,
  comm_type           text,
  capacity_ah         double precision,
  number_of_batteries integer,
  plant_id            bigint,
  plant_name          text,
  -- position in SunSynk's inverter list; the Overview tab renders cards in that
  -- order, so sorting by serial instead would swap the two cards
  ord                 integer
);

-- was: gaps (SQLite). Logger-offline windows awaiting cloud backfill.
create table if not exists private.gaps (
  from_ts bigint primary key,
  to_ts   bigint not null
);

-- ---------------------------------------------------------------------------
-- Local-day helper.
--
-- db.js expresses every daily rollup as strftime('%Y-%m-%d', ts,'unixepoch','localtime').
-- Rather than repeat the conversion across ~80 sites, define it once. IMMUTABLE
-- (the zone is a literal, not the session setting) so it can carry an index.
-- ---------------------------------------------------------------------------
create or replace function public.local_day(ts bigint)
returns date
language sql
immutable
parallel safe
as $$ select (to_timestamp(ts) at time zone 'Africa/Johannesburg')::date $$;

create or replace function public.local_hour(ts bigint)
returns integer
language sql
immutable
parallel safe
as $$ select extract(hour from (to_timestamp(ts) at time zone 'Africa/Johannesburg'))::int $$;

-- ---------------------------------------------------------------------------
-- public — dashboard data
-- ---------------------------------------------------------------------------

-- minute-aggregate spine. `source` distinguishes live logger samples from minutes
-- backfilled out of SunSynk's cloud; the recovery design keys off source='plantfeed'
-- and is reversible via DELETE ... WHERE source='plantfeed'. The original scaffold
-- omitted this column, which would have broken gap recovery silently.
create table if not exists public.agg_minute (
  ts     bigint primary key,
  pv_w   integer,
  load_w integer,
  batt_w integer,
  grid_w integer,
  soc    integer,
  source text
);
create index if not exists agg_minute_day_idx    on public.agg_minute (public.local_day(ts));
create index if not exists agg_minute_source_idx on public.agg_minute (source) where source is not null;

-- per-inverter readings — all 30 columns, matching the live SQLite table
create table if not exists public.readings (
  ts                     bigint,
  sn                     text,
  status                 integer,
  pv_w                   double precision,
  pv_today_kwh           double precision,
  pv_total_kwh           double precision,
  batt_power_w           double precision,
  batt_w                 double precision,
  batt_soc               double precision,
  batt_voltage_v         double precision,
  batt_current_a         double precision,
  batt_temp_c            double precision,
  batt_chg_today_kwh     double precision,
  batt_dischg_today_kwh  double precision,
  batt_chg_total_kwh     double precision,
  batt_dischg_total_kwh  double precision,
  grid_w                 double precision,
  grid_import_today_kwh  double precision,
  grid_export_today_kwh  double precision,
  grid_import_total_kwh  double precision,
  grid_export_total_kwh  double precision,
  grid_freq_hz           double precision,
  grid_pf                double precision,
  load_w                 double precision,
  load_today_kwh         double precision,
  load_total_kwh         double precision,
  load_freq_hz           double precision,
  output_w               double precision,
  output_volt_v          double precision,
  output_freq_hz         double precision,
  primary key (ts, sn)
);
create index if not exists readings_sn_ts_idx on public.readings (sn, ts desc);
create index if not exists readings_day_idx   on public.readings (public.local_day(ts));

-- per-string PV detail
create table if not exists public.strings (
  ts        bigint,
  sn        text,
  no        integer,
  volt_v    double precision,
  current_a double precision,
  power_w   double precision,
  today_kwh double precision,
  primary key (ts, sn, no)
);
create index if not exists strings_day_idx on public.strings (public.local_day(ts));

-- Cached SunSynk plant-level aggregates. These cover the plant's full lifetime,
-- predating our local logger, so they cannot be derived from agg_minute. A daily
-- cron refreshes them; the browser reads only this table and never SunSynk itself.
create table if not exists public.plant_energy (
  plant_id    bigint  not null,
  bucket      text    not null check (bucket in ('day', 'month')),
  period      date    not null,
  pv_kwh      double precision,
  load_kwh    double precision,
  imp_kwh     double precision,
  exp_kwh     double precision,
  chg_kwh     double precision,
  dischg_kwh  double precision,
  synced_at   timestamptz not null default now(),
  primary key (plant_id, bucket, period)
);

-- ---------------------------------------------------------------------------
-- RLS — authenticated reads only, and read-only at that. Writes arrive solely
-- through Edge Functions using service_role, which bypasses RLS entirely.
-- ---------------------------------------------------------------------------
alter table public.agg_minute   enable row level security;
alter table public.readings     enable row level security;
alter table public.strings      enable row level security;
alter table public.plant_energy enable row level security;

do $$
declare t text;
begin
  foreach t in array array['agg_minute', 'readings', 'strings', 'plant_energy'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (true)',
      t || '_read', t);
    -- belt and braces: even with a policy absent, anon holds no grant
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select on public.%I to authenticated', t);
    -- Writes come only from Edge Functions. auto_expose_new_tables = false means
    -- nothing is granted implicitly, so service_role needs this explicitly or the
    -- poller silently fails on every insert.
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end $$;
