-- ============================================================================
-- 0081 — readings and strings: one partition per UTC day, cut at day 61
-- (SOLAR-99).
--
-- Before (0070): monthly partitions, summarised into readings_5m / strings_5m and
-- dropped only once the whole month was past 60 days, so full detail lasted
-- 60-91 days. Deleting rows inside a partition frees no space (only a drop
-- does), so the extra month sat on disk: 422 of the free plan's 500 MB on
-- 14 Oct 2026, growing ~6 MB a day.
--
-- Now: one partition per UTC day. Every night private.rollup_old_days(61)
-- summarises each day older than 61 days into the 5-minute tables and drops
-- it. Inverter history and agg_minute already cut at 61 days (0071, 0072).
-- Nothing reads minute detail past 60 days: recover's gap refill reads
-- agg_minute, the string check 15 days, q_grid_feed_scale 30 days, and the
-- day and compare charts fall back to the 5-minute tables.
--
-- The monthly partitions still on record are split into day partitions by the
-- same nightly procedure, oldest first, one partition per commit, so only one
-- month is ever copied at a time (production peaks ~475 MB, not ~680 MB). Days
-- already past the line are summarised rather than copied. Splitting a
-- partition detaches it, which holds the parent's lock for the copy (a few
-- seconds at 04:30 UTC); a poll blocked past its 8 s timeout loses that minute.
-- The run stops starting new splits after 60 s (cluster statement_timeout is
-- 120 s) and carries on the next night.
--
-- This migration cannot run the split itself: a migration is one transaction,
-- so nothing would be freed until the end. Run it once after the push, or let
-- the 04:30 job do it:  call private.rollup_old_days(61);
-- ============================================================================

-- ── one day partition ───────────────────────────────────────────────────────
create or replace function private.ensure_day_partition(p_parent text, p_day date)
returns boolean
language plpgsql
set search_path = pg_temp
as $$
declare
  lo bigint := extract(epoch from p_day::timestamp at time zone 'UTC')::bigint;
  child text := format('%s_d%s', p_parent, to_char(p_day, 'YYYYMMDD'));
begin
  -- already covered, by a day partition or a monthly one not yet split
  if exists (
    select 1 from pg_inherits i join pg_class c on c.oid = i.inhrelid
     where i.inhparent = ('public.' || p_parent)::regclass
       and private.partbound_epoch(pg_get_expr(c.relpartbound, c.oid), 'FROM') <= lo
       and private.partbound_epoch(pg_get_expr(c.relpartbound, c.oid), 'TO')   >  lo) then
    return false;
  end if;
  execute format('create table public.%I partition of public.%I for values from (%s) to (%s)',
    child, p_parent, lo, lo + 86400);
  execute format('alter table public.%I enable row level security', child);
  return true;
end $$;

-- Day partitions for both tables from today (UTC) to p_days_ahead days on.
drop function if exists private.ensure_partitions(integer);
create function private.ensure_partitions(p_days_ahead integer default 14)
returns integer
language plpgsql
set search_path = pg_temp
as $$
declare t text; d date; made int := 0;
begin
  foreach t in array array['readings', 'strings'] loop
    for d in select generate_series((now() at time zone 'UTC')::date::timestamp,
                                    ((now() at time zone 'UTC')::date + p_days_ahead)::timestamp, interval '1 day')::date loop
      if private.ensure_day_partition(t, d) then made := made + 1; end if;
    end loop;
  end loop;
  return made;
end $$;

drop function if exists private.ensure_partition_range(regclass, text, timestamptz, timestamptz);

-- ── split one monthly partition into day partitions ─────────────────────────
-- Rows from p_cutoff on are copied into day partitions; older rows are
-- summarised into the 5-minute table. Then the monthly partition is dropped.
create or replace function private.split_partition(p_parent text, p_child text, p_cutoff bigint)
returns jsonb
language plpgsql
set search_path = pg_temp
as $$
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
end $$;

-- ── the nightly job ─────────────────────────────────────────────────────────
-- Oldest partition first across both tables. A day partition wholly before the
-- line is summarised and dropped; a partition longer than a day is split. One
-- commit per partition, so each drop frees its space before the next copy.
-- No SET clause: a procedure with one cannot commit. Every name is qualified.
create or replace procedure private.rollup_old_days(p_days integer default 61)
language plpgsql
as $$
declare
  cutoff bigint := extract(epoch from ((now() at time zone 'UTC')::date - p_days)::timestamp at time zone 'UTC')::bigint;
  started timestamptz := clock_timestamp();
  c record; n bigint; made bigint; r jsonb;
begin
  for c in
    select p.relname as parent, ch.relname as name,
           private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'FROM') as lo,
           private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'TO')   as hi
      from pg_inherits i
      join pg_class ch on ch.oid = i.inhrelid
      join pg_class p  on p.oid  = i.inhparent
     where i.inhparent in ('public.readings'::regclass, 'public.strings'::regclass)
     order by 3, 1
  loop
    if c.hi - c.lo > 86400 then
      -- a split copies up to a month; leave the rest for tomorrow's run
      if clock_timestamp() - started > interval '60 seconds' then
        raise notice 'rollup_old_days: stopping before %, out of time', c.name;
        exit;
      end if;
      r := private.split_partition(c.parent, c.name, cutoff);
      raise notice 'rollup_old_days: %', r;
    elsif c.hi <= cutoff then
      execute format('select count(*) from public.%I', c.name) into n;
      made := private.rollup_partition(c.parent, c.name);
      execute format('drop table public.%I', c.name);
      insert into private.partitions_dropped (partition_name, upper_bound, rows_dropped)
      values (c.name, to_timestamp(c.hi), n)
      on conflict (partition_name) do update
        set dropped_at = now(), upper_bound = excluded.upper_bound, rows_dropped = excluded.rows_dropped;
    else
      continue;
    end if;
    commit;
  end loop;
  -- the split made day partitions for its own month only
  perform private.ensure_partitions(14);
  commit;
end $$;

drop function if exists private.rollup_old_partitions(integer);

revoke all on function private.ensure_day_partition(text, date) from public, anon, authenticated;
revoke all on function private.ensure_partitions(integer) from public, anon, authenticated;
revoke all on function private.split_partition(text, text, bigint) from public, anon, authenticated;
revoke all on procedure private.rollup_old_days(integer) from public, anon, authenticated;

-- ── empty future months make way for day partitions ────────────────────────
do $$
declare c record; n bigint;
begin
  for c in
    select ch.relname as name
      from pg_inherits i join pg_class ch on ch.oid = i.inhrelid
     where i.inhparent in ('public.readings'::regclass, 'public.strings'::regclass)
       and private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'FROM') > extract(epoch from now())
       and private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'TO')
         - private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'FROM') > 86400
  loop
    execute format('select count(*) from public.%I', c.name) into n;
    if n > 0 then raise exception 'future partition % holds % rows', c.name, n; end if;
    execute format('drop table public.%I', c.name);
  end loop;
end $$;

select private.ensure_partitions(14);

-- ── cron ────────────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping jobs (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'rollup-old-partitions') then
    perform cron.unschedule('rollup-old-partitions');
  end if;
  if exists (select 1 from cron.job where jobname = 'ensure-partitions') then
    perform cron.unschedule('ensure-partitions');
  end if;
  perform cron.schedule('ensure-partitions', '0 3 * * *', 'select private.ensure_partitions(14)');
  perform cron.schedule('rollup-old-days', '30 4 * * *', 'call private.rollup_old_days(61)');
end $$;
