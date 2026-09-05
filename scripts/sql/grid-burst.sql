-- Sub-minute samples taken by `poll` after a relay-open / low-voltage minute
-- (table added in migration 0029). This is the view that can finally answer
-- 0017's open question: what does grid_volt_v read while the grid is DEAD?
--
-- Read it next to the trigger minute in `readings`. If grid_volt_v drops toward 0
-- somewhere in the burst while the relay is open, the 0015 premise holds and the
-- detection only needs a shorter debounce. If it stays at mains level throughout,
-- voltage is not the signal and the relay is.

select to_char(to_timestamp(b.ts) at time zone 'Africa/Johannesburg', 'MM-DD HH24:MI:SS') as sast,
       case when b.sn = '2508290475' then 'master' else 'slave' end  as inv,
       b.trigger,
       to_char(to_timestamp(b.trigger_ts) at time zone 'Africa/Johannesburg', 'HH24:MI') as fired_at,
       b.grid_relay_status                                          as relay,
       round(b.grid_volt_v::numeric, 1)                             as grid_v,
       round(b.grid_freq_hz::numeric, 2)                            as grid_hz,
       round(b.grid_w::numeric, 0)                                  as grid_w,
       round(b.output_volt_v::numeric, 1)                           as out_v,
       round(b.output_freq_hz::numeric, 2)                          as out_hz,
       round((b.grid_volt_v - b.output_volt_v)::numeric, 1)         as grid_minus_out_v
  from public.grid_burst b
 where b.ts >= extract(epoch from now())::bigint - 7 * 86400   -- last 7 days
 order by b.ts, b.sn;
