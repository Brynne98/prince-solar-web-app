CREATE OR REPLACE FUNCTION history.gap_queue(p_plant bigint, p_from bigint, p_to bigint, p_at timestamp with time zone DEFAULT now())
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into history.days (plant, day, kind, why, due_at)
  select p_plant, d::date, 'minutes', 'gap', p_at
    from generate_series((to_timestamp(p_from) at time zone plants.tz(p_plant))::date,
                         (to_timestamp(p_to) at time zone plants.tz(p_plant))::date, interval '1 day') d
  on conflict (plant, day, kind) where status = 'queued' do nothing
$function$;
