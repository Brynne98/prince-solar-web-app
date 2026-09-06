-- ============================================================================
-- 0033 — endpoint tiering: when each of load / output was last actually read.
--
-- After the freshness gate (0032) a fast datalogger still cost five calls a minute.
-- Of those, `load` and `output` carry nothing the minute spine needs every minute:
-- load follows from the energy balance (load ≈ pv + grid − batt, good to ~100 W,
-- DATA_PIPELINE §9A) and output only matters across an open relay. The poller now
-- reads `load` every 5 minutes and `output` every 10, both every minute while the
-- grid is down, and copies the previous values in between (load_w derived).
--
-- These two columns record the `ts` of the last minute the endpoint was actually
-- fetched; they are carried forward otherwise. So "derived load" is simply
-- `load_fetched_ts <> ts` — no extra marker column, and the integrity audit can
-- exclude those minutes with one predicate. Tiering is by age, not by ts % 5,
-- because a slow logger's real fetch minute rarely lands on a multiple of five.
--
-- Nullable on purpose: the old poller keeps landing rows between `db push` and
-- `functions deploy` (0032 lost a minute to a NOT NULL column).
-- ============================================================================

alter table public.readings
  add column if not exists load_fetched_ts   bigint,
  add column if not exists output_fetched_ts bigint;

comment on column public.readings.load_fetched_ts is
  'ts of the last minute /realtime/load was actually read for this inverter. load_w is derived (pv + grid − batt) on rows where this <> ts. Null before 0033.';
comment on column public.readings.output_fetched_ts is
  'ts of the last minute /realtime/output was actually read for this inverter; output_* columns are copied forward on rows where this <> ts. Null before 0033.';
