CREATE OR REPLACE PROCEDURE private.history_delete_run(IN p_cap interval DEFAULT '00:00:45'::interval, IN p_batch integer DEFAULT 5000)
 LANGUAGE plpgsql
AS $procedure$  -- no SET clause: a procedure with one cannot COMMIT
declare
  started timestamptz := clock_timestamp();
  q record;
  c record;
  t text;
  k text;
  n bigint;
  pass_rows bigint;
  t0 timestamptz;
  got boolean;
  no_fence boolean := false;
begin
  -- one run at a time; a session lock, as each commit lets transaction locks go
  if not pg_try_advisory_lock(8, 6590) then return; end if;

  <<plants>>
  loop
    exit when clock_timestamp() - started > p_cap;
    -- without the fence this run, only plants already fenced
    select * into q from private.history_delete_queue where not no_fence or fenced_at is not null
     order by queued_at, plant_id limit 1;
    exit when not found;

    -- the writers with no version check that began before the plant was listed end first;
    -- try, never queue for it (a queued take would stall every writer behind it)
    if q.fenced_at is null then
      t0 := clock_timestamp();
      got := false;
      for i in 1..50 loop
        if pg_try_advisory_xact_lock(8, 659) then got := true; exit; end if;
        perform pg_sleep(0.1);
      end loop;
      if not got then no_fence := true; continue; end if;
      update private.history_delete_queue
         set fenced_at = clock_timestamp(), wait_ms = wait_ms + round(extract(epoch from clock_timestamp() - t0) * 1000)
       where plant_id = q.plant_id;
      commit;
    end if;

    pass_rows := 0;
    -- raw minutes: one day partition at a time
    for c in select ch.oid::regclass::text as rel, pa.relname as parent
               from pg_inherits i join pg_class ch on ch.oid = i.inhrelid join pg_class pa on pa.oid = i.inhparent
              where i.inhparent in ('public.readings'::regclass, 'public.strings'::regclass)
              order by pa.relname, ch.relname loop
      loop
        exit plants when clock_timestamp() - started > p_cap;
        t0 := clock_timestamp();
        begin
          execute format('delete from %s where ctid = any (array(select ctid from %s where plant_id = $1 limit $2))', c.rel, c.rel)
            using q.plant_id, p_batch;
          get diagnostics n = row_count;
        exception when undefined_table then
          n := 0;   -- the nightly rollup dropped the day meanwhile
        end;
        update private.history_delete_queue
           set raw_ms = raw_ms + round(extract(epoch from clock_timestamp() - t0) * 1000),
               counts = counts || jsonb_build_object(c.parent, coalesce((counts->>c.parent)::bigint, 0) + n)
         where plant_id = q.plant_id;
        commit;
        pass_rows := pass_rows + n;
        exit when n < p_batch;
      end loop;
    end loop;

    -- a rollup slice that read the raw rows before they went ends first, so its 5-minute
    -- rows are there to delete below (it holds (8, 651) exclusive; nothing is locked here).
    -- Tried, not waited for: the run keeps to its cap; the next run carries on.
    t0 := clock_timestamp();
    got := false;
    for i in 1..50 loop
      if pg_try_advisory_xact_lock_shared(8, 651) then got := true; exit; end if;
      perform pg_sleep(0.1);
    end loop;
    exit plants when not got;
    update private.history_delete_queue set wait_ms = wait_ms + round(extract(epoch from clock_timestamp() - t0) * 1000)
     where plant_id = q.plant_id;
    commit;

    -- sources before what is made from them
    foreach t in array array['public.agg_minute', 'public.inverter_history', 'public.readings_5m', 'public.strings_5m',
                             'public.agg_5m', 'public.inverter_history_5m', 'public.plant_energy', 'public.grid_off',
                             'private.gaps', 'private.grid_off_progress'] loop
      k := split_part(t, '.', 2);
      loop
        exit plants when clock_timestamp() - started > p_cap;
        t0 := clock_timestamp();
        execute format('delete from %s where ctid = any (array(select ctid from %s where plant_id = $1 limit $2))', t, t)
          using q.plant_id, p_batch;
        get diagnostics n = row_count;
        update private.history_delete_queue
           set rest_ms = rest_ms + round(extract(epoch from clock_timestamp() - t0) * 1000),
               counts = counts || jsonb_build_object(k, coalesce((counts->>k)::bigint, 0) + n)
         where plant_id = q.plant_id;
        commit;
        pass_rows := pass_rows + n;
        exit when n < p_batch;
      end loop;
    end loop;

    -- a whole pass found nothing: done
    update private.history_delete_queue set passes = passes + 1 where plant_id = q.plant_id;
    if pass_rows = 0 then
      insert into private.history_delete_log (plant_id, caller, timeout, wait_ms, raw_ms, rest_ms, counts)
      select plant_id, 'worker', current_setting('statement_timeout', true), wait_ms, raw_ms, rest_ms, counts
        from private.history_delete_queue where plant_id = q.plant_id;
      delete from private.history_delete_queue where plant_id = q.plant_id;
    end if;
    commit;
  end loop;

  perform pg_advisory_unlock(8, 6590);
end $procedure$;
