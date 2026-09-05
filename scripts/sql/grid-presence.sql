-- Was the grid actually off, and when?
--
-- The Live tab's "Grid on / Grid off" chip only ever reflects the newest logged
-- minute (api_overview reads max(ts) from readings), so it cannot answer this
-- after the fact. The per-minute rows can.
--
-- grid_volt_v is the signal that settles it: mains reads ~230 V whenever the
-- utility is live, even at zero current, and collapses to ~0 in a real outage.
-- NULL means the firmware did not report -- "we do not know", not "off".
-- See migration 0015_grid_presence.sql.
--
-- Any minute where grid_present is false is an outage minute. false with
-- relay = '1' is the unambiguous case: still connected, no mains.

select to_timestamp(ts) at time zone 'Africa/Johannesburg'      as sast,
       count(*)                                                 as inverters,
       count(grid_volt_v)                                       as reporting,
       round(max(grid_volt_v)::numeric, 1)                      as max_volt,
       string_agg(distinct coalesce(grid_relay_status, '-'), '/') as relay,
       round(sum(grid_w)::numeric, 0)                           as grid_w,
       max(grid_freq_hz)                                        as hz,
       case when count(grid_volt_v) = 0 then null
            else bool_or(grid_volt_v > 100) end                 as grid_present
  from public.readings
 where ts >= extract(epoch from now())::bigint - 10800   -- last 3 hours
 group by ts
 order by ts;
