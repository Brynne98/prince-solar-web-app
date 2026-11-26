CREATE OR REPLACE FUNCTION private.split_partition(p_parent text, p_child text, p_cutoff bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_temp'
AS $function$
declare
  c record; lo bigint; hi bigint; d date;
  n_all bigint; n_keep bigint; n_moved bigint; made bigint := 0;
begin
  select pg_get_expr(ch.relpartbound, ch.oid) as bound into c
    from pg_class ch where ch.oid = ('public.' || p_child)::regclass;
  lo := private.partbound_epoch(c.bound, 'FROM');
  hi := private.partbound_epoch(c.bound, 'TO');

  execute format('alter table public.%I detach partition public.%I', p_parent, p_child);
  execute format('select count(*), count(*) filter (where ts >= %s) from public.%I', p_cutoff, p_child)
    into n_all, n_keep;

  for d in select generate_series(to_timestamp(greatest(lo, p_cutoff)) at time zone 'UTC',
                                  to_timestamp(hi - 1) at time zone 'UTC', interval '1 day')::date loop
    perform private.ensure_day_partition(p_parent, d);
  end loop;

  execute format('insert into public.%I select * from public.%I where ts >= %s', p_parent, p_child, p_cutoff);
  get diagnostics n_moved = row_count;
  if n_moved <> n_keep then
    raise exception 'split_partition %: copied % of % rows', p_child, n_moved, n_keep;
  end if;

  if n_all > n_keep then
    if n_keep > 0 then
      execute format('delete from public.%I where ts >= %s', p_child, p_cutoff);
    end if;
    made := private.rollup_partition(p_parent, p_child);
  end if;

  execute format('drop table public.%I', p_child);
  insert into private.partitions_dropped (partition_name, upper_bound, rows_dropped)
  values (p_child, to_timestamp(hi), n_all - n_keep)
  on conflict (partition_name) do update
    set dropped_at = now(), upper_bound = excluded.upper_bound, rows_dropped = excluded.rows_dropped;
  return jsonb_build_object('split', p_child, 'kept', n_keep, 'summarised', n_all - n_keep, 'buckets', made);
end $function$;
