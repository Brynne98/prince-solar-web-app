CREATE OR REPLACE FUNCTION history.totals_now(p_plant bigint)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into history.totals as t (plant, full_sweep, due_at) values (p_plant, true, now())
  on conflict (plant) do update set full_sweep = true, due_at = least(t.due_at, excluded.due_at)
  returning true
$function$;
