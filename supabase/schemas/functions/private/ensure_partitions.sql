CREATE OR REPLACE FUNCTION private.ensure_partitions(p_days_ahead integer DEFAULT 7)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'pg_temp'
AS $function$
declare t text; d date; made int := 0;
begin
  foreach t in array array['readings', 'strings'] loop
    for d in select generate_series((now() at time zone 'UTC')::date::timestamp,
                                    ((now() at time zone 'UTC')::date + p_days_ahead)::timestamp, interval '1 day')::date loop
      if private.ensure_day_partition(t, d) then made := made + 1; end if;
    end loop;
  end loop;
  return made;
end $function$;
