CREATE OR REPLACE PROCEDURE private.history_delete_check(IN p_slow_ms integer DEFAULT 3000)
 LANGUAGE plpgsql
AS $procedure$  -- no SET clause: a procedure with one cannot COMMIT
declare
  w record;
begin
  delete from private.history_delete_log where at < now() - interval '90 days';
  commit;  -- kept when the alarm below fails the run

  select * into w from (
    select plant_id::text as what, caller, wait_ms + raw_ms + rest_ms as ms, wait_ms, raw_ms, rest_ms
      from private.history_delete_log where at > now() - interval '24 hours' and caller <> 'worker'   -- 0277
    union all
    select count(*) || ' plants', min(caller), sum(wait_ms + raw_ms + rest_ms), sum(wait_ms), sum(raw_ms), sum(rest_ms)
      from private.history_delete_log where at > now() - interval '24 hours' and caller in ('authenticated', 'service_role')
     group by xid having count(*) > 1
  ) t where ms > p_slow_ms order by ms desc limit 1;
  if found then
    raise exception 'history delete over % ms in 24 h: % % % ms (wait %, raw %, rest %), see SOLAR-659',
      p_slow_ms, w.what, w.caller, w.ms, w.wait_ms, w.raw_ms, w.rest_ms;
  end if;

  select plant_id, queued_at, passes, counts into w from private.history_delete_queue          -- 0277
   where queued_at < now() - interval '1 hour' order by queued_at limit 1;
  if found then
    raise exception 'history of plant % waiting to be deleted since % (% passes, so far %), see SOLAR-659',
      w.plant_id, w.queued_at, w.passes, w.counts;
  end if;
end $procedure$;
