CREATE OR REPLACE FUNCTION public.q_insert_recovered(p_plant bigint, p_rows jsonb, p_source text DEFAULT 'plantfeed'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare n integer;
begin
  if p_source not in ('plantfeed', 'invhistory') then
    raise exception 'q_insert_recovered: unknown source %', p_source;
  end if;
  with ins as (
    insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
    select p_plant, (r->>'ts')::bigint,
           nullif(r->>'pv_w','')::integer,   nullif(r->>'load_w','')::integer,
           nullif(r->>'batt_w','')::integer, nullif(r->>'grid_w','')::integer,
           nullif(r->>'soc','')::integer,    p_source
      from jsonb_array_elements(p_rows) r
    on conflict (plant_id, ts) do update
      set pv_w = excluded.pv_w, load_w = excluded.load_w, batt_w = excluded.batt_w,
          grid_w = excluded.grid_w, soc = excluded.soc, source = excluded.source
      where agg_minute.source = 'poller_partial'
    returning 1)
  select count(*) into n from ins;
  return n;
end $function$;
