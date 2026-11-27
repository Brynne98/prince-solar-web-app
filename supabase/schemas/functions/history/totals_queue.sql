CREATE OR REPLACE FUNCTION history.totals_queue(p_at timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with ins as (
    insert into history.totals as t (plant, full_sweep, due_at)
    select r.plant, extract(dow from p_at at time zone plants.tz(r.plant)) = 0, p_at
      from (select distinct plant from billing.reading_routes(p_at)) r
    on conflict (plant) do update set full_sweep = t.full_sweep or excluded.full_sweep, due_at = least(t.due_at, excluded.due_at)
    returning 1)
  select count(*)::integer from ins
$function$;
