CREATE OR REPLACE PROCEDURE private.rollup_old_days(IN p_days integer DEFAULT 31, IN p_cap interval DEFAULT '00:01:00'::interval, IN p_target_rows integer DEFAULT 25000, IN p_slow interval DEFAULT '00:00:02'::interval)
 LANGUAGE plpgsql
AS $procedure$
declare
  cutoff  bigint := extract(epoch from ((now() at time zone 'UTC')::date - p_days)::timestamp at time zone 'UTC')::bigint;
  started timestamptz := clock_timestamp();
  my_pid  integer := pg_backend_pid();
  my_qs   timestamptz;
  skip    oid[] := '{}';
  c record; pr record;
  est double precision; w integer; t_to bigint; n_in bigint; n_out bigint;
  p bigint; live boolean; got boolean;
  t_key timestamptz; slow_ms integer := 0; slow_part text; busy boolean; have boolean;
begin
  if p_days is null or p_days < 1 then
    raise exception 'rollup_old_days: p_days must be 1 or more, got %', p_days;
  end if;
  select query_start into my_qs from pg_stat_activity where pid = my_pid;

  -- register partitions past the line; forget rows whose partition is gone or changed
  -- a partition replaced under the same name after part of it was rolled up: the new
  -- rows can't overwrite the buckets already written (on conflict do nothing), so stop
  -- and alert rather than drop the new raw rows. Clear by hand once checked.
  if exists (select 1 from private.rollup_progress g
              where g.next_ts > g.lo and to_regclass(format('public.%I', g.part_name)) is not null
                and not private.rollup_part_ok(g.part_oid, g.part_name, g.parent, g.lo, g.hi)) then
    raise exception 'rollup_old_days: % replaced after part of it was rolled up; check its 5-minute rows, then delete its rollup_progress row',
      (select string_agg(g.part_name, ', ') from private.rollup_progress g
        where g.next_ts > g.lo and to_regclass(format('public.%I', g.part_name)) is not null
          and not private.rollup_part_ok(g.part_oid, g.part_name, g.parent, g.lo, g.hi));
  end if;
  delete from private.rollup_progress g
   where not private.rollup_part_ok(g.part_oid, g.part_name, g.parent, g.lo, g.hi);
  for c in
    select p.relname as parent, ch.oid, ch.relname as name, ch.reltuples,
           private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'FROM') as lo,
           private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'TO')   as hi
      from pg_inherits i
      join pg_class ch on ch.oid = i.inhrelid
      join pg_class p  on p.oid  = i.inhparent
     where i.inhparent in ('public.readings'::regclass, 'public.strings'::regclass)
     order by 6, 1
  loop
    continue when c.hi > cutoff;
    -- a monthly, default or open-ended partition: not this job's
    if c.lo is null or c.hi is null or c.hi - c.lo <> 86400 or c.lo % 300 <> 0 then
      raise notice 'rollup_old_days: % is not a day partition, skipped', c.name;
      continue;
    end if;
    continue when exists (select 1 from private.rollup_progress where part_oid = c.oid);
    -- rows a day: the planner's count, or the size on disk when it has none yet
    -- (pg_relation_size locks the table, so only for one not registered yet)
    est := greatest(c.reltuples, pg_relation_size(c.oid) / case when c.parent = 'readings' then 200 else 80 end, 1);
    w := least(86400, greatest(300, floor(p_target_rows * 86400.0 / est / 300) * 300))::integer;
    insert into private.rollup_progress (part_oid, part_name, parent, lo, hi, next_ts, width)
    values (c.oid, c.name, c.parent, c.lo, c.hi, c.lo, w)
    on conflict (part_oid) do nothing;
  end loop;
  commit;

  <<work>>
  loop
    exit when clock_timestamp() - started > p_cap;
    select * into pr from private.rollup_progress
     where hi <= cutoff and part_oid <> all (skip) order by lo, parent limit 1;
    exit when not found;

    if pr.next_ts < pr.hi or cardinality(pr.redo) > 0 then
      -- ── a slice or a redo: the key, then the partition as registered ──
      if not private.rollup_try_key() then exit work; end if;
      select * into pr from private.rollup_progress where part_oid = pr.part_oid;
      if not found then commit; continue; end if;
      -- never wait for the table while holding the key: a history delete waits on the key
      busy := false;
      begin
        execute format('lock table public.%I in access share mode nowait', pr.part_name);
      exception
        when undefined_table then null;
        when lock_not_available then busy := true;
      end;
      if busy then commit; exit work; end if;
      if not private.rollup_part_ok(pr.part_oid, pr.part_name, pr.parent, pr.lo, pr.hi) then
        if pr.next_ts > pr.lo and to_regclass(format('public.%I', pr.part_name)) is not null then
          raise exception 'rollup_old_days: % replaced after part of it was rolled up; check its 5-minute rows, then delete its rollup_progress row',
            pr.part_name;
        end if;
        -- dropped, or replaced before any slice: forget it; a new one registers next run
        raise notice 'rollup_old_days: % changed since it was registered, progress dropped', pr.part_name;
        delete from private.rollup_progress where part_oid = pr.part_oid;
        commit;
        continue;
      end if;
      -- another run finished it meanwhile: let go of the key before the drop
      if pr.next_ts >= pr.hi and cardinality(pr.redo) = 0 then commit; continue; end if;
    end if;

    if pr.next_ts < pr.hi then
      -- ── a slice: mark it, then do it ──
      w := pr.width;
      if pr.attempt_pid is not null then
        perform pg_stat_clear_snapshot();
        select exists (select 1 from pg_stat_activity
                        where pid = pr.attempt_pid and pid <> my_pid
                          and state = 'active' and query_start = pr.attempt_qstart) into live;
        if live then commit; exit work; end if;
        -- the last slice died: half as wide for the rest of this partition
        w := greatest(300, (pr.attempt_width / 2 / 300) * 300);
        raise notice 'rollup_old_days: % slice of % s died, now % s', pr.part_name, pr.attempt_width, w;
      end if;
      update private.rollup_progress
         set width = w, attempt_width = w, attempt_pid = my_pid, attempt_qstart = my_qs, updated_at = now()
       where part_oid = pr.part_oid;
      commit;

      if not private.rollup_try_key() then
        -- a history delete or the sign check came in between: undo our mark, try later
        update private.rollup_progress set attempt_width = null, attempt_pid = null, attempt_qstart = null
         where part_oid = pr.part_oid and attempt_pid = my_pid and attempt_qstart = my_qs;
        commit;
        exit work;
      end if;
      t_key := clock_timestamp();
      select * into pr from private.rollup_progress where part_oid = pr.part_oid;
      if not found or pr.attempt_pid is distinct from my_pid or pr.attempt_qstart is distinct from my_qs then
        commit; continue;
      end if;
      -- never wait for the table while holding the key: a history delete waits on the key
      busy := false;
      begin
        execute format('lock table public.%I in access share mode nowait', pr.part_name);
      exception
        when undefined_table then null;
        when lock_not_available then busy := true;
      end;
      if busy then
        update private.rollup_progress set attempt_width = null, attempt_pid = null, attempt_qstart = null
         where part_oid = pr.part_oid and attempt_pid = my_pid and attempt_qstart = my_qs;
        commit;
        exit work;
      end if;
      if not private.rollup_part_ok(pr.part_oid, pr.part_name, pr.parent, pr.lo, pr.hi) then
        commit; continue;   -- the check at the top of the next turn forgets it
      end if;
      t_to := least(pr.next_ts + pr.width, pr.hi);
      execute format('select count(*) from public.%I where ts >= %s and ts < %s', pr.part_name, pr.next_ts, t_to)
        into n_in;
      perform private.rollup_partition(pr.parent, pr.part_name, pr.next_ts, t_to);
      update private.rollup_progress
         set next_ts = t_to, rows_in = rows_in + n_in,
             attempt_width = null, attempt_pid = null, attempt_qstart = null, updated_at = now()
       where part_oid = pr.part_oid;
      commit;
      if clock_timestamp() - t_key > p_slow and pr.width > 300 then
        -- held the key too long: narrower from the next slice on
        update private.rollup_progress set width = greatest(300, (width / 2 / 300) * 300)
         where part_oid = pr.part_oid;
        commit;
      elsif pr.width = 300 and extract(epoch from clock_timestamp() - t_key) * 1000 > slow_ms then
        -- the slowest slice that can't get narrower: the early warning for SOLAR-659
        slow_ms := (extract(epoch from clock_timestamp() - t_key) * 1000)::integer;
        slow_part := pr.part_name;
      end if;

    elsif cardinality(pr.redo) > 0 then
      -- ── one plant again, from raw rows its sign check flipped (readings only) ──
      p := pr.redo[1];
      if pr.parent = 'readings' then
        delete from public.readings_5m where plant_id = p and ts >= pr.lo and ts < pr.hi;
        n_out := private.rollup_partition(pr.parent, pr.part_name, pr.lo, pr.hi, p);
        raise notice 'rollup_old_days: % redone for plant %, % buckets', pr.part_name, p, n_out;
      end if;
      update private.rollup_progress set redo = array_remove(redo, p), updated_at = now()
       where part_oid = pr.part_oid;
      commit;

    else
      -- ── the drop: every lock without waiting, a few tries ──
      got := false;
      for i in 1..10 loop
        begin
          execute format('lock table only public.%I in access exclusive mode nowait', pr.parent);
          if not pg_try_advisory_xact_lock(8, 651) then
            raise exception 'rollup key busy' using errcode = 'lock_not_available';
          end if;
          select * into pr from private.rollup_progress where part_oid = pr.part_oid;
          have := found;
          if have then
            -- the child too, before reading its bounds (that locks it), all without waiting
            begin
              execute format('lock table public.%I in access exclusive mode nowait', pr.part_name);
            exception when undefined_table then
              null;
            end;
          end if;
          if not have then
            null;   -- another run dropped it
          elsif not private.rollup_part_ok(pr.part_oid, pr.part_name, pr.parent, pr.lo, pr.hi) then
            if to_regclass(format('public.%I', pr.part_name)) is not null then
              raise exception 'rollup_old_days: % replaced after part of it was rolled up; check its 5-minute rows, then delete its rollup_progress row',
                pr.part_name;
            end if;
            delete from private.rollup_progress where part_oid = pr.part_oid;
          elsif pr.next_ts >= pr.hi and cardinality(pr.redo) = 0 then
            execute format('drop table public.%I', pr.part_name);
            insert into private.partitions_dropped (partition_name, upper_bound, rows_dropped)
            values (pr.part_name, to_timestamp(pr.hi), pr.rows_in)
            on conflict (partition_name) do update
              set dropped_at = now(), upper_bound = excluded.upper_bound, rows_dropped = excluded.rows_dropped;
            delete from private.rollup_progress where part_oid = pr.part_oid;
          end if;
          got := true;
        exception when lock_not_available then
          got := false;
        end;
        if got then commit; exit; end if;
        rollback;
        perform pg_sleep(0.2);
      end loop;
      if not got then
        raise notice 'rollup_old_days: % busy, drop left for the next run', pr.part_name;
        skip := skip || pr.part_oid;
      end if;
    end if;
  end loop;

  -- the slow-slice alarm stays up for 24 h, so the cron check can't miss a one-off
  if slow_ms > extract(epoch from p_slow) * 1000 then
    insert into private.rollup_slow (part_name, ms) values (slow_part, slow_ms);
  end if;
  delete from private.rollup_slow where at < now() - interval '30 days';
  commit;

  if exists (select 1 from private.rollup_progress where created_at < now() - interval '24 hours') then
    raise exception 'rollup_old_days: % waiting over 24 h, not yet rolled up and dropped',
      (select string_agg(part_name, ', ' order by lo, parent) from private.rollup_progress
        where created_at < now() - interval '24 hours');
  end if;
  select part_name, ms into slow_part, slow_ms from private.rollup_slow
   where at > now() - interval '24 hours' order by ms desc limit 1;
  if found then
    raise exception 'rollup_old_days: a 300 s slice of % held the rollup key % ms in the last 24 h; plants are near the limit, see SOLAR-659',
      slow_part, slow_ms;
  end if;
end $procedure$;
