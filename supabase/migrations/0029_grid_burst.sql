-- ============================================================================
-- Sub-minute grid samples around a relay-open event.
--
-- On 2026-09-04 at 11:15 SAST the master logged its first relay-open minute
-- (acRealyStatus 0, 0 Hz, 0 W, output pinned to 230.0 V / 50.00 Hz) while a ~2
-- minute outage was happening. grid_volt_v read 242.9 V in that same row.
--
-- That row does NOT answer the question 0017 left open. With the relay closed,
-- grid_volt_v and output_volt_v are the same number (mean |diff| 0.06 V over 5,759
-- minutes -- one AC bus). At 11:15 they differed by 12.9 V, so the two sensors sit on
-- opposite sides of the relay, and the grid-side one saw mains: the utility was back
-- and the inverter was still inside its reconnect delay. The dead-grid interval fell
-- between one-minute polls. A ~2 minute event can yield zero samples of the thing
-- we actually need to see.
--
-- So: when a poll sees the relay open (or grid voltage under 100 V), the poller now
-- takes a short burst of extra samples at ~10 s spacing and stores them here. Only
-- the grid and output endpoints are fetched (2 calls per inverter per sample) and
-- only while the trigger condition was observed, so the cost is nothing in normal
-- running and a few dozen calls during an event.
--
-- A separate table, not sub-minute rows in `readings`: every consumer of `readings`
-- assumes a one-per-minute spine (api_overview takes max(ts), q_grid_present takes a
-- ts, day aggregation integrates at 1/min). Off-minute rows would silently corrupt
-- those.
--
-- `trigger_ts` is the poll minute that started the burst; `trigger` says why.
-- ============================================================================

create table if not exists public.grid_burst (
  ts                 bigint not null,          -- epoch seconds, NOT minute-aligned
  sn                 text   not null,
  plant_id           bigint not null,
  trigger            text   not null,          -- 'relay_open' | 'low_volt'
  trigger_ts         bigint not null,          -- the poll minute that fired the burst
  grid_volt_v        double precision,         -- nullable: absent field must not read as 0 V
  grid_relay_status  text,
  grid_freq_hz       double precision,
  grid_w             double precision,
  output_volt_v      double precision,
  output_freq_hz     double precision,
  primary key (ts, sn)
);

comment on table public.grid_burst is
  'Sub-minute grid/output samples taken by `poll` for ~50 s after a relay-open or low-voltage minute. Exists to observe what this firmware reports while the grid is actually dead -- see 0017 and 0029.';

create index if not exists grid_burst_plant_ts_idx on public.grid_burst (plant_id, ts desc);
create index if not exists grid_burst_trigger_idx  on public.grid_burst (plant_id, trigger_ts);

-- Same visibility rule as readings (0024 §4): a user sees their own plants only.
alter table public.grid_burst enable row level security;
drop policy if exists grid_burst_read on public.grid_burst;
create policy grid_burst_read on public.grid_burst for select to authenticated
  using (plant_id in (select public.my_plant_ids()));

grant select on public.grid_burst to authenticated;
grant all    on public.grid_burst to service_role;
