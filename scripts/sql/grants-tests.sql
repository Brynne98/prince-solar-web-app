-- SOLAR-692: a function a signed-in user runs as themselves (security invoker) can only call
-- functions they may run too. LOCAL database only, every migration applied. One transaction,
-- rolled back:   psql "$DB" -v ON_ERROR_STOP=1 -f scripts/sql/grants-tests.sql

begin;
set client_min_messages = notice;

create temp table t_results (n serial, label text, pass boolean, detail text);
create function pg_temp.ok(p_label text, p_cond boolean, p_detail text default null)
returns void language sql as $$
  insert into t_results (label, pass, detail) values (p_label, coalesce(p_cond, false), p_detail)
$$;

-- Every invoker function signed-in users may run, against every function in our schemas they
-- may not: a call by name is a page that errors (independence_pct, 2026-11-27).
do $$
declare gaps text;
begin
  select string_agg(c.fn || ' -> ' || d.fn, '; ' order by c.fn, d.fn) into gaps
    from (select p.oid::regprocedure::text fn, p.prosrc from pg_proc p
           where p.pronamespace::regnamespace::text in ('public', 'plants', 'billing', 'msg')
             and not p.prosecdef and has_function_privilege('authenticated', p.oid, 'execute')) c
    join (select distinct p.pronamespace::regnamespace::text || '.' || p.proname fn, p.proname from pg_proc p
           where p.pronamespace::regnamespace::text in ('public', 'plants', 'billing', 'msg', 'private')
             and not has_function_privilege('authenticated', p.oid, 'execute')) d
      on c.prosrc ~ ('(^|[^a-z0-9_])' || d.proname || '\s*\(');
  perform pg_temp.ok('G1 no invoker function a user runs calls one they may not', gaps is null, gaps);
end $$;

-- The browser's past-day path, run as a signed-in user (the outcome is kept in a setting: the
-- results table is not theirs to write)
set local role authenticated;
do $$
begin
  perform set_config('g.row', coalesce(public._energy_row('day', date '2026-11-26', 47.7, 54.4, 0, 3, 25.4, 37.4)::text, 'null'), true);
  perform set_config('g.live', (public.grid_live(230) and not public.grid_live(12))::text, true);
exception when others then
  perform set_config('g.row', 'error: ' || sqlerrm, true);
end $$;
reset role;
do $$
begin
  perform pg_temp.ok('G2 a past-day row as a signed-in user',
    current_setting('g.row', true) like '{%', current_setting('g.row', true));
  perform pg_temp.ok('G3 grid_live as a signed-in user', current_setting('g.live', true) = 'true',
    current_setting('g.row', true));
end $$;

do $$
declare n int; bad text;
begin
  select count(*), string_agg(label || coalesce(': ' || detail, ''), E'\n') filter (where not pass)
    into n, bad from t_results;
  if bad is not null then raise exception E'checks failed:\n%', bad; end if;
  raise notice 'all % checks passed', n;
end $$;
rollback;
