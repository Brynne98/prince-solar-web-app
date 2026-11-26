CREATE OR REPLACE FUNCTION billing.plant_state(p_plant bigint, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  purged boolean;
  se record;
  st billing.status;
  is_protected boolean := false;
  is_read boolean := false;
  latest timestamptz;
  seat_count int := 0;
  delete_at timestamptz;
begin
  if not exists (select 1 from plants.plants where id = p_plant) then return null; end if;
  purged := exists (select 1 from billing.plant_facts f where f.plant = p_plant and f.history_purged_at is not null);
  for se in select s.account from billing.seats s
             where s.plant = p_plant and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  loop
    seat_count := seat_count + 1;
    st := billing.account_status(se.account, p_at);
    if st.state in ('trialing', 'active', 'past_due') then
      is_protected := true;
      if not st.must_choose and billing.has_route(se.account, p_plant, true) then is_read := true; end if;
    elsif st.state = 'ended' and st.access_ended_at is not null then
      latest := greatest(latest, st.access_ended_at + make_interval(days => st.retention_days));
    end if;
  end loop;
  is_read := is_read and not private.history_deleting(p_plant);           -- 0277
  delete_at := case when is_protected or purged then null
                    when seat_count = 0 then p_at
                    else latest end;
  return jsonb_build_object(
    'plant', p_plant,
    'protected', is_protected,
    'read_now', is_read,
    'delete_at', delete_at,
    'purged', purged,
    'deleting', private.history_deleting(p_plant),                        -- 0277
    'open_seats', seat_count);
end $function$;
