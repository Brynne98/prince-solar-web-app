CREATE OR REPLACE FUNCTION history.check_queue(p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  p bigint; tz text; today date; fl bigint; d date; lo bigint; hi bigint; have bigint;
  now_ts bigint := extract(epoch from p_at)::bigint;
  queued int := 0; extras int := 0; given_up int;
begin
  update history.days x set status = 'given_up', note = 'left the 14-day window', closed_at = p_at,
                            claim = null, claimed_until = null
   where x.status = 'queued' and x.why in ('gap', 'check')
     and x.day < (p_at at time zone plants.tz(x.plant))::date - 13
     and (x.claimed_until is null or x.claimed_until <= p_at);
  get diagnostics given_up = row_count;
  for p in select distinct r.plant from billing.reading_routes(p_at) r order by 1 loop
    tz := plants.tz(p);
    today := (p_at at time zone tz)::date;
    fl := history.floor_ts(p);
    continue when fl is null;
    for d in select today - g from generate_series(0, 13) g loop
      lo := greatest(public.day_start_epoch_tz(d, tz), (ceil(fl / 60.0) * 60)::bigint);
      hi := least(public.day_start_epoch_tz(d + 1, tz), ((now_ts - 600) / 60) * 60);
      continue when hi <= lo;
      select count(*) into have from public.agg_minute a
       where a.plant_id = p and a.ts >= lo and a.ts < hi and a.source <> 'poller_partial' and a.ts % 60 = 0;
      if have < (hi - lo) / 60 then
        insert into history.days (plant, day, kind, why, due_at) values (p, d, 'minutes', 'check', p_at)
        on conflict (plant, day, kind) where status = 'queued' do nothing;
        queued := queued + 1;
      end if;
    end loop;
    if not history.has_extras(p, today - 1) then
      insert into history.days (plant, day, kind, why, due_at) values (p, today - 1, 'extras', 'check', p_at)
      on conflict (plant, day, kind) where status = 'queued' do nothing;
      extras := extras + 1;
    end if;
  end loop;
  perform history.clean(p_at);
  return jsonb_build_object('minute_days', queued, 'extras_days', extras, 'given_up', given_up);
end $function$;
