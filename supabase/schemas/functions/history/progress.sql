CREATE OR REPLACE FUNCTION history.progress(p_plant bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with i as (select x.* from history.imports x where x.plant = p_plant and x.status = 'open'),
  q as (select d.kind, count(*) as total, count(*) filter (where d.status = 'queued') as todo,
               max(d.day) filter (where d.status = 'queued') as top
          from history.days d join i on d.import = i.id group by d.kind),
  s as (select public.today_tz(plants.tz(p_plant)) as today, plants.tz(p_plant) as tz)
  select jsonb_build_object(
    'fetching', exists (select 1 from i),
    'percent', case when exists (select 1 from i)
                    then floor(100.0 * coalesce(sum(q.total - q.todo), 0) / greatest(coalesce(sum(q.total), 0), 1))::int end,
    'floor', (select i.floor_day from i),
    'minutesTo', (select q.top from q where q.kind = 'minutes'),
    'extrasTo', (select q.top from q where q.kind = 'extras'),
    'days', case when exists (select 1 from i) then
              (select count(*) from s, generate_series(0, history.days_back() - 1) g(n)
                where exists (select 1 from public.agg_minute a
                               where a.plant_id = p_plant
                                 and a.ts >= public.day_start_epoch_tz(s.today - g.n, s.tz)
                                 and a.ts <  public.day_start_epoch_tz(s.today - g.n + 1, s.tz))
                   or exists (select 1 from public.agg_5m f
                               where f.plant_id = p_plant
                                 and f.ts >= public.day_start_epoch_tz(s.today - g.n, s.tz)
                                 and f.ts <  public.day_start_epoch_tz(s.today - g.n + 1, s.tz)))
            else history.days_back() end,
    'window', history.days_back())
  from q
$function$;
