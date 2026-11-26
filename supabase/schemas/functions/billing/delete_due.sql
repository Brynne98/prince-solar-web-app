CREATE OR REPLACE FUNCTION billing.delete_due(p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  p record;
  ps jsonb;
  deleted bigint[] := '{}';
  emptied bigint[] := '{}';
  held bigint[] := '{}';
  busy bigint[] := '{}';
  counts jsonb;
  out jsonb;
  now_at timestamptz;
begin
  if not billing.is_live() then return jsonb_build_object('live', false); end if;
  if not pg_try_advisory_xact_lock(hashtext('billing.delete_due')) then return jsonb_build_object('busy', true); end if;
  for p in select id from billing.plants where history_purged_at is null order by id loop
    ps := billing.plant_state(p.id, p_at);
    continue when ps->>'delete_at' is null or (ps->>'delete_at')::timestamptz > p_at;
    -- a plant being written now is left for the next run
    perform 1 from billing.plants where id = p.id for update skip locked;
    if not found then busy := busy || p.id; continue; end if;
    -- the clock moved while the job ran: one time from here on, after the lock, for every
    -- check and the delete itself; a seat opened since the job started keeps the plant
    now_at := greatest(p_at, clock_timestamp());
    ps := billing.plant_state(p.id, now_at);
    continue when ps->>'delete_at' is null or (ps->>'delete_at')::timestamptz > now_at;
    continue when exists (select 1 from billing.seats s where s.plant = p.id and s.closed_at is null and s.chosen_at > p_at);
    if billing.payment_hold(p.id, now_at) then held := held || p.id; continue; end if;
    -- the full routine every time; what went is read from its counts
    counts := billing.purge_now(p.id, now_at);
    continue when counts is null;
    if exists (select 1 from jsonb_each_text(counts) c where c.value::bigint > 0) then deleted := deleted || p.id;
    else emptied := emptied || p.id; end if;
  end loop;
  out := jsonb_build_object('deleted', to_jsonb(deleted), 'empty', cardinality(emptied),
                            'held', to_jsonb(held), 'busy', to_jsonb(busy));
  perform billing.heartbeat('delete', p_at, out);
  return out;
end $function$;
