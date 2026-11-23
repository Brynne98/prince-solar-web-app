-- ============================================================================
-- 0244 — billing redesign phase 2: the payment tables (SOLAR-641).
--
-- Bills and tries are separate (design v2 item 2):
--   invoices          one per purchase, renewal, change or card check. Plan,
--                     interval, period and amount are frozen on it. Receipts read it.
--   payment_attempts  many per invoice. Each has its own Paystack reference,
--                     written before the charge call. At most one success per
--                     invoice. claimed_until is a lease, so the daily job and a
--                     manual Pay cannot charge the same invoice at once.
--   payment_methods   saved cards (Paystack authorization).
--   payment_events    every webhook, stored first; a duplicate stops, a stored
--                     event that never finished is processed again.
--   refunds           against the original attempt; failed ones are retried.
--
-- Payment rows outlive account delete: the account reference is cleared, no cascade.
-- ============================================================================

-- Paystack's smallest charge in this market (ZAR: R1). Smaller upgrade amounts are waived.
alter table billing.markets add column min_charge_minor int not null default 100 check (min_charge_minor > 0);

create table billing.payment_methods (
  id              uuid primary key default gen_random_uuid(),
  account         uuid references billing.accounts (id) on delete set null,
  provider        text not null,
  customer_code   text,
  auth_ref        text not null,                 -- Paystack authorization_code
  auth_email      text,                          -- the email the card was saved under
  reusable        boolean not null,
  signature       text,
  card_type       text,
  last4           text,
  exp_month       smallint check (exp_month between 1 and 12),
  exp_year        smallint,
  active          boolean not null default true,
  disabled_reason text check (disabled_reason in ('replaced', 'hard_decline', 'dispute', 'reversed', 'not_reusable')),
  created_at      timestamptz not null default now(),
  unique (provider, auth_ref),
  check (active = (disabled_reason is null)),
  check (not active or reusable)
);
create unique index payment_methods_one_active on billing.payment_methods (account) where active;

create table billing.invoices (
  id                uuid primary key default gen_random_uuid(),
  account           uuid references billing.accounts (id) on delete set null,
  subscription      uuid references billing.subscriptions (id) on delete set null,
  kind              text not null check (kind in ('purchase', 'renewal', 'upgrade', 'card_check')),
  status            text not null default 'open' check (status in ('open', 'paid', 'void', 'waived')),
  price             uuid references billing.prices (id),
  plan              text references billing.plans (code),
  plan_name         text,                        -- the plan's name when the bill was made (receipts, Payments)
  interval          text check (interval in ('month', 'year')),
  offer             text references billing.offers (code),
  extra_places      int not null default 0 check (extra_places >= 0),
  plan_amount_minor int check (plan_amount_minor >= 0),   -- the recurring amount after this bill (plan price, before extra places)
  extra_place_minor int not null default 0 check (extra_place_minor >= 0),
  amount_minor      int not null check (amount_minor >= 0), -- what this bill charges
  tax_minor         int,
  currency          text not null,
  period_start      timestamptz,                 -- a purchase: set when paid
  period_end        timestamptz,
  period_key        text,                        -- renewal: the period start; upgrade: period start + target
  expected_version  bigint,                      -- accounts.version at checkout (purchase, upgrade)
  plants            bigint[],                    -- the final plant choice, applied with the payment
  amount_owed_minor int not null default 0 check (amount_owed_minor >= 0),  -- a lost dispute on an old period
  created_at        timestamptz not null,
  paid_at           timestamptz,
  check ((status = 'paid') = (paid_at is not null)),
  check (kind = 'card_check' or plan is not null),
  check (period_end is null or period_end > period_start)
);
create unique index invoices_one_per_period on billing.invoices (subscription, period_key, kind)
  where period_key is not null and status <> 'void';
create index invoices_account on billing.invoices (account, created_at desc);

-- Every bill keeps the plan's name as it was when the bill was made, whichever command made it.
create function billing.invoice_plan_name()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
begin
  new.plan_name := coalesce(new.plan_name, (select name from billing.plans where code = new.plan));
  return new;
end $$;
create trigger invoices_plan_name before insert on billing.invoices
  for each row execute function billing.invoice_plan_name();
create index invoices_open on billing.invoices (subscription) where status = 'open';

create table billing.payment_attempts (
  id               uuid primary key default gen_random_uuid(),
  invoice          uuid not null references billing.invoices (id),
  reference        text not null unique,
  provider         text not null,
  channel          text not null check (channel in ('saved_card', 'card_page', 'none')),
  payment_method   uuid references billing.payment_methods (id),
  amount_minor     int  not null check (amount_minor >= 0),
  currency         text not null,
  -- created: written, charge call not answered yet. pending: card page open, bank
  -- challenge, or still processing. unknown: no clear answer, verify before any new try.
  -- void: never reached Paystack, or the owner left the card page. not_applied: money taken
  -- but not applied, refunded. reversed: paid, then Paystack gave the money back.
  status           text not null check (status in ('created', 'pending', 'unknown', 'success', 'failed', 'void', 'not_applied', 'reversed')),
  claimed_until    timestamptz,
  gateway_response text,
  hard_decline     boolean not null default false,
  pay_url          text,                         -- bank challenge: the owner finishes it here
  dispute_status   text,
  dispute_open     boolean not null default false,
  dispute_id       text,                         -- Paystack's dispute id
  dispute_resolved_at timestamptz,               -- a resolved dispute is final
  created_at       timestamptz not null,
  settled_at       timestamptz
);
create unique index payment_attempts_one_success on billing.payment_attempts (invoice) where status = 'success';
create index payment_attempts_invoice on billing.payment_attempts (invoice, created_at);
create index payment_attempts_unresolved on billing.payment_attempts (claimed_until) where status in ('created', 'pending', 'unknown');

-- Paystack webhooks carry no event id: one row per (provider, event type, entity id, status).
create table billing.payment_events (
  id           bigint generated always as identity primary key,
  provider     text not null,
  event_type   text not null,
  entity_id    text not null,
  status       text not null default '',
  payload      jsonb,
  received_at  timestamptz not null,
  processed_at timestamptz,
  tries        int not null default 1,
  last_error   text,
  unique (provider, event_type, entity_id, status)
);

create table billing.refunds (
  id                 uuid primary key default gen_random_uuid(),
  attempt            uuid references billing.payment_attempts (id),
  reference          text not null,              -- the transaction refunded
  account            uuid references billing.accounts (id) on delete set null,
  amount_minor       int,                        -- null: the whole payment
  currency           text,
  reason             text not null check (reason in ('stale', 'duplicate', 'unknown_account', 'wrong_amount', 'card_check', 'manual', 'reversed')),
  status             text not null check (status in ('due', 'sending', 'pending', 'processed', 'failed')),
  tries              int not null default 0,
  last_error         text,
  provider_refund_id text unique,
  claimed_until      timestamptz,
  next_try_at        timestamptz,
  created_at         timestamptz not null,
  updated_at         timestamptz not null
);
create unique index refunds_one_auto on billing.refunds (reference) where reason <> 'manual';
create index refunds_to_send on billing.refunds (next_try_at) where status in ('due', 'failed', 'sending');

-- Emails to send, intent only (design: "The outbox stores intent only"). Phase 4 renders
-- and sends them from account_state at send time; dedupe_key makes each one once.
create table billing.outbox (
  id          bigint generated always as identity primary key,
  account     uuid references billing.accounts (id) on delete set null,
  key         text not null,                     -- the message, e.g. card_update
  invoice     uuid references billing.invoices (id),
  dedupe_key  text not null unique,
  not_before  timestamptz not null,
  expires_at  timestamptz,
  status      text not null default 'queued' check (status in ('queued', 'sent', 'dropped')),
  sent_at     timestamptz,
  created_at  timestamptz not null
);

revoke all on all tables in schema billing from public, anon, authenticated;
grant select on all tables in schema billing to service_role;
