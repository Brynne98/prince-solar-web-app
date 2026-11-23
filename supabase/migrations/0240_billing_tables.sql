-- ============================================================================
-- 0240 — billing redesign phase 1: the new tables (SOLAR-641).
--
-- Design: reports/billing-redesign-2026-11-22.md (v2 and Round 4 win over v1).
-- Stored facts only. State, counts, open places, read-now and delete dates are
-- worked out by billing.account_state / billing.plant_state (0241).
--
-- Own schema `billing`, not exposed to the API: private.offers already uses the
-- name "offers", and the old tables stay in use until the switch-over. Nothing old
-- reads these tables yet. Writes go through the commands in 0242 only.
--
-- Plant ids are today's plant ids (reading tables stay keyed by them).
-- Money is in minor units (cents). Yearly = 10 monthly.
-- ============================================================================

create schema if not exists billing;
revoke all on schema billing from public, anon, authenticated;
grant usage on schema billing to service_role;

-- Per country: currency, clock, free week, retry days, how long history is kept.
create table billing.markets (
  code              text primary key,
  currency          text not null check (currency ~ '^[A-Z]{3}$'),
  default_time_zone text not null,
  trial_days        int  not null check (trial_days > 0),
  trial_places      int  not null check (trial_places > 0),
  retry_days        int[] not null check (cardinality(retry_days) > 0),
  retention_days    int  not null check (retention_days >= 0),
  payment_provider  text not null
);

insert into billing.markets (code, currency, default_time_zone, trial_days, trial_places, retry_days, retention_days, payment_provider)
values ('ZA', 'ZAR', 'Africa/Johannesburg', 7, 5, '{0,3,7,14}', 30, 'paystack');

create table billing.accounts (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null unique references auth.users (id) on delete cascade,
  market           text not null references billing.markets (code),
  time_zone        text,                         -- null: the market's
  locale           text not null default 'en-ZA',
  trial_started_at timestamptz,
  trial_ends_at    timestamptz,                  -- moved earlier when the account pays in its week
  version          bigint not null default 0,    -- bumped by every command (stale checkout guard)
  created_at       timestamptz not null default now(),
  check ((trial_started_at is null) = (trial_ends_at is null)),
  check (trial_ends_at >= trial_started_at)
);

-- Inverter logins. secret_ref is the vault id of the stored password/refresh token.
create table billing.logins (
  id         uuid primary key default gen_random_uuid(),
  account    uuid not null references billing.accounts (id) on delete cascade,
  brand      text not null,
  username   text not null,
  secret_ref uuid,
  status     text not null default 'ok' check (status in ('ok', 'needs_reconnect')),
  created_at timestamptz not null default now(),
  unique (account, brand, username)
);

create table billing.plants (
  id                bigint primary key,
  brand             text not null,
  external_id       text not null,
  trial_used_at     timestamptz,                 -- this plant's free week was used
  trial_used_by     uuid references billing.accounts (id) on delete set null,
  history_purged_at timestamptz,                 -- a finished delete; cleared by new readings
  version           bigint not null default 0,
  unique (brand, external_id),
  check (trial_used_by is null or trial_used_at is not null)
);

-- A plant on two logins has two rows here and at most one seat per account.
create table billing.login_plants (
  login        uuid   not null references billing.logins (id) on delete cascade,
  plant        bigint not null references billing.plants (id),
  plant_name   text,
  last_seen_at timestamptz,
  gone_at      timestamptz,                      -- no longer on the login's list
  primary key (login, plant)
);
create index login_plants_plant on billing.login_plants (plant);

-- A plant shared to our service login, claimed by one account. First claim wins.
create table billing.plant_claims (
  plant      bigint primary key references billing.plants (id),
  account    uuid not null references billing.accounts (id) on delete cascade,
  claimed_at timestamptz not null default now(),
  plant_name text                       -- the share login's name for it, at the claim
);
create index plant_claims_account on billing.plant_claims (account);

-- The only record of "chosen".
create table billing.seats (
  id                 uuid primary key default gen_random_uuid(),
  account            uuid   not null references billing.accounts (id) on delete cascade,
  plant              bigint not null references billing.plants (id),
  chosen_at          timestamptz not null,
  closed_at          timestamptz,
  close_reason       text check (close_reason in ('switched', 'login_removed', 'dropped', 'support')),
  drop_at_period_end boolean not null default false,
  check ((closed_at is null) = (close_reason is null)),
  check (closed_at >= chosen_at)
);
create unique index seats_one_open on billing.seats (account, plant) where closed_at is null;
create index seats_plant_open on billing.seats (plant) where closed_at is null;

create table billing.plans (
  code         text primary key,
  name         text not null,
  places       int  not null check (places > 0),
  allows_extra boolean not null default false
);
insert into billing.plans (code, name, places, allows_extra) values
  ('home',   'Home',   2, false),
  ('family', 'Family', 5, true);

create table billing.offers (
  code            text primary key,
  first_time_only boolean not null default true,
  valid_from      timestamptz not null,
  valid_until     timestamptz,
  max_members     int check (max_members > 0)
);
-- 0145 / private.offers 'launch': valid from 2026-11-03, 100 places.
insert into billing.offers (code, first_time_only, valid_from, valid_until, max_members)
values ('launch', true, '2026-11-03 00:00 Africa/Johannesburg', null, 100);

create table billing.prices (
  id                uuid primary key default gen_random_uuid(),
  plan              text not null references billing.plans (code),
  market            text not null references billing.markets (code),
  interval          text not null check (interval in ('month', 'year')),
  amount_minor      int  not null check (amount_minor >= 0),
  extra_place_minor int  not null default 0 check (extra_place_minor >= 0),
  tax_minor         int,
  offer             text references billing.offers (code),
  active_from       timestamptz not null,
  active_until      timestamptz,
  check (active_until is null or active_until > active_from)
);
create unique index prices_one_live on billing.prices (plan, market, interval, coalesce(offer, ''))
  where active_until is null;

-- Today's prices (0156, private.offers 'launch'). Extra places are not sold now;
-- the amounts are kept for accounts that still hold them.
insert into billing.prices (plan, market, interval, amount_minor, extra_place_minor, offer, active_from) values
  ('home',   'ZA', 'month',   9900,     0, null,     '2026-11-06 00:00 Africa/Johannesburg'),
  ('home',   'ZA', 'year',   99000,     0, null,     '2026-11-06 00:00 Africa/Johannesburg'),
  ('family', 'ZA', 'month',  19900,  4900, null,     '2026-11-06 00:00 Africa/Johannesburg'),
  ('family', 'ZA', 'year',  199000, 58800, null,     '2026-11-06 00:00 Africa/Johannesburg'),
  ('home',   'ZA', 'month',   4900,     0, 'launch', '2026-11-03 00:00 Africa/Johannesburg'),
  ('home',   'ZA', 'year',   49000,     0, 'launch', '2026-11-03 00:00 Africa/Johannesburg'),
  ('family', 'ZA', 'month',   9900,  2900, 'launch', '2026-11-03 00:00 Africa/Johannesburg'),
  ('family', 'ZA', 'year',   99000, 29000, 'launch', '2026-11-03 00:00 Africa/Johannesburg');

-- Amounts are copied at purchase so later price changes never touch a member.
-- The trial has no row here.
create table billing.subscriptions (
  id                   uuid primary key default gen_random_uuid(),
  account              uuid not null references billing.accounts (id) on delete cascade,
  price                uuid references billing.prices (id),
  plan                 text not null references billing.plans (code),
  currency             text not null,
  interval             text not null check (interval in ('month', 'year')),
  amount_minor         int  not null check (amount_minor >= 0),
  extra_place_minor    int  not null default 0 check (extra_place_minor >= 0),
  extra_places         int  not null default 0 check (extra_places >= 0),
  offer                text references billing.offers (code),
  status               text not null check (status in ('active', 'past_due', 'ended')),
  started_at           timestamptz not null,
  billing_day          smallint not null check (billing_day between 1 and 31),
  period_start         timestamptz not null,
  period_end           timestamptz not null,
  past_due_since       timestamptz,              -- the first failed try (day 0); set only while past_due
  cancel_at_period_end boolean not null default false,
  next_price           uuid references billing.prices (id),
  next_extra_places    int check (next_extra_places >= 0),
  ended_at             timestamptz,
  version              bigint not null default 0,
  created_at           timestamptz not null default now(),
  check (period_end > period_start),
  check ((status = 'past_due') = (past_due_since is not null)),
  check ((status = 'ended') = (ended_at is not null))
);
create unique index subscriptions_one_live on billing.subscriptions (account) where status in ('active', 'past_due');
create index subscriptions_account on billing.subscriptions (account, started_at desc);

-- An offer price is for first-time members only: refused if the account had any plan before.
-- Upgrades and other changes update the running row, so they keep the offer.
create function billing.offer_first_time_only()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
begin
  if new.offer is not null
     and exists (select 1 from billing.offers o where o.code = new.offer and o.first_time_only)
     and exists (select 1 from billing.subscriptions s where s.account = new.account and s.id <> new.id) then
    raise exception 'the launch price is for first-time members only' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger subscriptions_offer_first_time before insert on billing.subscriptions
  for each row execute function billing.offer_first_time_only();

-- Support or comped places; count as an active plan with no billing.
create table billing.grants (
  id        uuid primary key default gen_random_uuid(),
  account   uuid not null references billing.accounts (id) on delete cascade,
  places    int  not null check (places > 0),
  reason    text not null,
  starts_at timestamptz not null,
  ends_at   timestamptz,
  check (ends_at is null or ends_at > starts_at)
);
create index grants_account on billing.grants (account);

-- Append-only log written by every command. No foreign key: it outlives the account.
create table billing.account_events (
  id      bigint generated always as identity primary key,
  account uuid not null,
  at      timestamptz not null,
  actor   text not null,
  kind    text not null,
  before  jsonb,
  after   jsonb,
  reason  text
);
create index account_events_account on billing.account_events (account, at);

revoke all on all tables in schema billing from public, anon, authenticated;
grant select on all tables in schema billing to service_role;
revoke all on function billing.offer_first_time_only() from public, anon, authenticated;
