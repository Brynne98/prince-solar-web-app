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
-- Any minute where grid_present is false is an outage minute. This calls the
-- deployed q_grid_present rather than re-deriving it, so it agrees with the Live
-- chip and the alerts. Since 0055 that function answers from the rows carrying the
-- newest device_time, because a datalogger that has not uploaded must not out-vote
-- one that has -- a frozen 240.1 V hid the first two minutes of the 18 Sep outage.
--
-- The relay is no longer part of the test. Anti-islanding opens it within seconds of
-- losing mains, so a real blackout always reads '0' and the reading is not evidence
-- either way. It is still shown here, because it dates the reconnect: on 18 Sep the
-- volts came back at 17:18:14 and the relay stayed open for another 92 seconds.

select plant_id,
       to_timestamp(ts) at time zone 'Africa/Johannesburg'      as sast,
       count(*)                                                 as inverters,
       count(grid_volt_v)                                       as reporting,
       round(max(grid_volt_v)::numeric, 1)                      as max_volt,
       string_agg(distinct coalesce(grid_relay_status, '-'), '/') as relay,
       round(sum(grid_w)::numeric, 0)                           as grid_w,
       max(grid_freq_hz)                                        as hz,
       public.q_grid_present(plant_id, ts)                      as grid_present
  from public.readings
 where ts >= extract(epoch from now())::bigint - 10800   -- last 3 hours
 group by plant_id, ts
 order by ts;
