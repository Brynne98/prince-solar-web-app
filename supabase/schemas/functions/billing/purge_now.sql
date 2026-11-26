CREATE OR REPLACE FUNCTION billing.purge_now(p_plant bigint, p_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare ps jsonb;
begin
  if not billing.is_live() then return null; end if;
  ps := billing.plant_state(p_plant, p_at);
  if ps->>'delete_at' is null or (ps->>'delete_at')::timestamptz > p_at or billing.payment_hold(p_plant, p_at) then
    return null;
  end if;
  -- 0277: the rows go in the background (private.history_delete_run); from here the plant
  -- is hidden, not read and not written while it waits
  insert into private.history_delete_queue (plant_id, queued_at) values (p_plant, clock_timestamp())
  on conflict (plant_id) do nothing;
  delete from private.refill_queue where plant_id = p_plant;
  update public.plant_config set backfill_next = null, backfill_until = null, backfill_tries = 0, temp_next = null
   where plant_id = p_plant;
  insert into billing.plant_facts (plant, history_purged_at) values (p_plant, p_at)
  on conflict (plant) do update set history_purged_at = excluded.history_purged_at;
  perform plants.bump(array[p_plant]);
  update billing.history_fetches set status = 'dropped', drop_reason = 'deleted', finished_at = p_at, claimed_until = null
   where plant = p_plant and status in ('queued', 'running');
  return jsonb_build_object('queued', 1);                                  -- 0277: delete_due counts it as deleted
end $function$;
