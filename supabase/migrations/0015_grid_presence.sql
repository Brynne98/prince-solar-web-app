-- ============================================================================
-- Store whether the grid is PRESENT, not just whether it is being used.
--
-- Nothing logged so far can answer "is the grid off?". grid_w says how much power is
-- crossing the CT and grid_freq_hz reads zero whenever none is, so a blackout and a
-- quiet solar afternoon are byte-identical: both show 0 W and 0 Hz. Measured over the
-- logged history, 54% of all minutes read zero frequency, including single stretches
-- of 2-4 days — those are commissioning and off-grid running, not outages.
--
-- GRID VOLTAGE is the signal that settles it. It reads mains voltage whenever the
-- utility is live, whether or not any current is flowing, and collapses to zero when
-- the supply actually fails. `acRealyStatus` (SunSynk's spelling, not ours) is stored
-- alongside it as a cross-check.
--
-- Both come from /grid/{sn}/realtime, which the poller already fetches — API.md has
-- listed them as available-and-unused all along. So this costs no extra API call.
--
-- NULL vs ZERO MATTERS HERE, and it is the whole reason these columns are nullable
-- with no default. If SunSynk does not return the field, or returns something we
-- cannot parse, the value must be NULL — "we do not know" — and the dashboard shows
-- nothing. Coercing a missing field to 0 would render as GRID OFF permanently, which
-- is worse than saying nothing at all.
--
-- No history: this works from the first poll after deployment onward, and nothing can
-- reconstruct it for the past. The values want eyeballing on first capture, since
-- nothing has yet verified what this firmware actually returns.
-- ============================================================================

alter table public.readings
  add column if not exists grid_volt_v         double precision,
  add column if not exists grid_relay_status   text;

comment on column public.readings.grid_volt_v is
  'Grid/mains voltage from /grid realtime vip[0]. Live utility supply reads ~230 V even at zero current; a genuine outage reads ~0. NULL = not reported.';
comment on column public.readings.grid_relay_status is
  'Raw acRealyStatus (SunSynk''s spelling) from /grid realtime — cross-check for grid_volt_v. Stored verbatim as text because the value domain is unverified.';

-- ---------------------------------------------------------------------------
-- Grid presence for the dashboard.
--
-- 100 V is deliberately a long way below nominal 230 V: this is asking "is the utility
-- there at all", and a brownout should still count as present. Above the threshold on
-- ANY inverter counts, since one may sit behind a CT that reports nothing.
--
-- Returns NULL, not false, when no inverter reported a voltage — so the UI can tell
-- "grid is off" apart from "this firmware doesn't tell us".
-- ---------------------------------------------------------------------------
create or replace function public.q_grid_present(p_ts bigint)
returns boolean language sql stable as $$
  select case when count(grid_volt_v) = 0 then null
              else bool_or(grid_volt_v > 100) end
    from public.readings where ts = p_ts
$$;

revoke all on function public.q_grid_present(bigint) from public, anon;
grant execute on function public.q_grid_present(bigint) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Surface grid presence on the snapshot the Live tab reads.
--
-- Rebuilt wholesale rather than patched because api_overview() is one statement. The
-- only change from 0006 is the `gridPresent` key on `totals`, which is:
--     true  = mains voltage seen on at least one inverter
--     false = every reporting inverter saw ~0 V, i.e. the supply is down
--     null  = no inverter reported a voltage, i.e. we do not know yet
-- ---------------------------------------------------------------------------
create or replace function public.api_overview()
returns jsonb
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  with latest as (select max(ts) as ts from public.readings),
  r as (select rd.* from public.readings rd, latest where rd.ts = latest.ts),
  -- per-inverter strings for the same minute
  st as (
    select s.sn, jsonb_agg(jsonb_build_object(
             'id', null, 'no', s.no, 'power', s.power_w,
             'voltage', s.volt_v, 'current', s.current_a, 'today', s.today_kwh)
           order by s.no) as strings
      from public.strings s, latest
     where s.ts = latest.ts group by s.sn
  ),
  inv as (
    select r.sn,
           jsonb_build_object(
             'sn', r.sn,
             'alias', coalesce(m.alias, r.sn),
             'model', m.model,
             'status', r.status,
             'gsn', m.gsn,
             'soft', m.soft_ver,
             'hmi', m.hmi_ver,
             'commType', m.comm_type,
             'pv', jsonb_build_object(
               'power', round(r.pv_w), 'today', r.pv_today_kwh, 'total', r.pv_total_kwh,
               'strings', coalesce(st.strings, '[]'::jsonb)),
             'battery', jsonb_build_object(
               'power', round(abs(r.batt_w)),
               -- signedPower is normalised at ingestion (+ = charging), so direction
               -- is just the sign; no firmware convention leaks out here
               'signedPower', round(r.batt_w),
               'status', case when r.batt_w > 5 then 'charging'
                              when r.batt_w < -5 then 'discharging' else 'idle' end,
               'soc', r.batt_soc, 'voltage', r.batt_voltage_v, 'current', r.batt_current_a,
               'temperature', r.batt_temp_c,   -- raw, incl. junk like -100
               'capacity', m.capacity_ah, 'numberOfBatteries', m.number_of_batteries,
               'todayCharged', r.batt_chg_today_kwh, 'todayDischarged', r.batt_dischg_today_kwh,
               'totalCharged', r.batt_chg_total_kwh, 'totalDischarged', r.batt_dischg_total_kwh),
             'grid', jsonb_build_object(
               'power', round(r.grid_w),
               'direction', case when r.grid_w >= 0 then 'importing' else 'exporting' end,
               'todayImport', r.grid_import_today_kwh, 'todayExport', r.grid_export_today_kwh,
               'totalImport', r.grid_import_total_kwh, 'totalExport', r.grid_export_total_kwh,
               'frequency', r.grid_freq_hz, 'powerFactor', r.grid_pf),
             'load', jsonb_build_object(
               'power', round(r.load_w), 'today', r.load_today_kwh,
               'total', r.load_total_kwh, 'frequency', r.load_freq_hz),
             'output', jsonb_build_object(
               'power', round(r.output_w), 'voltage', r.output_volt_v,
               'frequency', r.output_freq_hz)) as snap,
           r.pv_w, r.load_w, r.grid_w, r.batt_w, r.batt_soc,
           r.pv_today_kwh, r.grid_import_today_kwh, r.grid_export_today_kwh,
           -- SunSynk's own list order; rows migrated from SQLite have none yet and
           -- fall back to serial order until the next poll fills it in
           coalesce(m.ord, 9999) as ord
      from r
      left join private.meta m on m.sn = r.sn
      left join st on st.sn = r.sn
  ),
  totals as (
    select sum(round(pv_w)) as pv, sum(round(load_w)) as load,
           sum(round(grid_w)) as grid, sum(round(batt_w)) as batt,
           -- average SOC over inverters with a VALID reading only: a dropped BMS
           -- link reports 0, which would otherwise halve the displayed SOC
           avg(batt_soc) filter (where batt_soc > 0) as soc,
           sum(pv_today_kwh) as today_pv,
           sum(grid_import_today_kwh) as today_imp,
           sum(grid_export_today_kwh) as today_exp
      from inv
  ),
  -- grid presence: mains voltage on ANY inverter (see q_grid_present, above)
  gp as (
    select case when count(grid_volt_v) = 0 then null else bool_or(grid_volt_v > 100) end as present
      from r
  ),
  -- Grid import/export today integrated from our OWN logger. The per-inverter
  -- counter only populates on the CT-bearing master, so summing snapshots
  -- under-counts by ~half. Same source the day chart uses.
  grid_today as (
    select coalesce(sum(case when grid_w > 0 then grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           coalesce(sum(case when grid_w < 0 then -grid_w * (5.0/60) / 1000 else 0 end), 0) as exp,
           count(*) as n
      from public.q_day_agg((now() at time zone 'Africa/Johannesburg')::date, null)
  ),
  plant as (
    select m.plant_id as id, m.plant_name as name
      from private.meta m where m.plant_id is not null order by m.sn limit 1
  )
  select jsonb_build_object(
    'generatedAt', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'plant', jsonb_build_object(
      'id', (select id from plant),
      'name', coalesce((select name from plant), 'Home · SunSynk')),
    'totals', jsonb_build_object(
      'pv', t.pv, 'load', t.load, 'grid', t.grid,
      'gridDirection', case when t.grid >= 0 then 'importing' else 'exporting' end,
      'batteryPower', abs(t.batt),
      'batteryDirection', case when abs(t.batt) <= 5 then 'idle'
                               when t.batt > 0 then 'charging' else 'discharging' end,
      'soc', case when t.soc is null then null else round(t.soc) end,
      'todayPv', round(t.today_pv::numeric, 2),
      'todayGridImport', round((case when g.n > 5 then g.imp else t.today_imp end)::numeric, 2),
      'todayGridExport', round((case when g.n > 5 then g.exp else t.today_exp end)::numeric, 2),
      'gridPresent', (select present from gp)),
    'inverters', coalesce((select jsonb_agg(snap order by ord, sn) from inv), '[]'::jsonb))
  from totals t, grid_today g
$$;

revoke all on function public.api_overview() from public, anon;
grant execute on function public.api_overview() to authenticated, service_role;
