CREATE OR REPLACE FUNCTION private.grid_off_update(p_plant bigint, p_to bigint DEFAULT NULL::bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  hi   bigint := coalesce(p_to, (extract(epoch from now())::bigint / 60) * 60 - 120);
  lo   bigint;
  open public.grid_off;
  m    record;
  n    integer := 0;
begin
  perform private.history_fence();                                         -- 0277
  if private.history_deleting(p_plant) then return 0; end if;
  select through_ts into lo from private.grid_off_progress where plant_id = p_plant;
  if lo is null then
    select min(r.ts) into lo from public.readings r where r.plant_id = p_plant;
  end if;
  if lo is null or lo >= hi then return 0; end if;

  select * into open from public.grid_off
   where plant_id = p_plant and ended_at is null
   order by started_at desc limit 1;

  for m in select * from private.grid_minutes(p_plant, lo, hi) order by ts loop
    n := n + 1;
    if not m.present then
      if open.plant_id is null then
        open := (p_plant, to_timestamp(m.ts), null, to_timestamp(m.ts), 0)::public.grid_off;
      end if;
      open.last_off_at := to_timestamp(m.ts);
      open.minutes_off := open.minutes_off + 1;
    elsif open.plant_id is not null then
      open.ended_at := to_timestamp(m.ts);
      insert into public.grid_off values (open.*)
      on conflict (plant_id, started_at) do update
        set ended_at = excluded.ended_at, last_off_at = excluded.last_off_at,
            minutes_off = excluded.minutes_off;
      open := null;
    end if;
  end loop;

  if open.plant_id is not null then
    insert into public.grid_off values (open.*)
    on conflict (plant_id, started_at) do update
      set last_off_at = excluded.last_off_at, minutes_off = excluded.minutes_off;
  end if;

  insert into private.grid_off_progress (plant_id, through_ts) values (p_plant, hi)
  on conflict (plant_id) do update set through_ts = excluded.through_ts;
  return n;
end $function$;
