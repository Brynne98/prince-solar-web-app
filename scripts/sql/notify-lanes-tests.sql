-- SOLAR-645 step 2 (0257): email_claim lanes and job_check_push.
-- LOCAL database only, with every migration applied. One transaction, rolled back:
--   psql "$DB" -v ON_ERROR_STOP=1 -f scripts/sql/notify-lanes-tests.sql
-- Exit 0: every check passed. A failed check raises, so psql exits 3.

begin;
set client_min_messages = notice;

create temp table t_results (n serial, label text, pass boolean, detail text);
create function pg_temp.ok(p_label text, p_cond boolean, p_detail text default null)
returns void language sql as $$
  insert into t_results (label, pass, detail) values (p_label, coalesce(p_cond, false), p_detail)
$$;

-- one user with no plant: an alert (priority 0), a welcome (1) and a need-a-hand (2), all due
do $$
declare u uuid := gen_random_uuid(); a bigint; w bigint; h bigint; got bigint[];
begin
  insert into auth.users (id, email, created_at) values (u, 'lanes@notify.test', now() - interval '1 day');
  delete from public.email_queue where user_id = u;     -- the confirm trigger's own rows
  insert into public.email_queue (user_id, kind, key, data, priority, due_at)
  values (u, 'grid_down', 'grid_down:lanes', jsonb_build_object('since', extract(epoch from now())::bigint), 0, now() - interval '1 minute')
  returning id into a;
  insert into public.email_queue (user_id, kind, key, priority, due_at) values (u, 'welcome', 'welcome:lanes', 1, now() - interval '2 minutes') returning id into w;
  insert into public.email_queue (user_id, kind, key, priority, due_at) values (u, 'need_a_hand', 'need_a_hand:lanes', 2, now() - interval '3 minutes') returning id into h;

  got := array(select id from public.email_claim(100, true, 'urgent') where user_id = u);
  perform pg_temp.ok('L1 urgent lane: the alert only', got = array[a], got::text);
  got := array(select id from public.email_claim(100, true, 'bulk') where user_id = u order by id);
  perform pg_temp.ok('L2 bulk lane: everything but the alert', got = array[w, h], got::text);
  got := array(select id from public.email_claim(100, true) where user_id = u);
  perform pg_temp.ok('L3 no lane (old two-argument call): all three, alert first', got = array[a, w, h], got::text);
  got := array(select id from public.email_claim(100, false, 'urgent') where user_id = u);
  perform pg_temp.ok('L4 a real urgent claim marks only the alert sending',
    (select array_agg(status order by id) from public.email_queue where id in (a, w, h)) = array['sending', 'queued', 'queued'],
    (select array_agg(status order by id) from public.email_queue where id in (a, w, h))::text);
end $$;

-- pop-ups waiting: alert rows with no pop-up handled, 5 min to 1 h old
do $$
declare u uuid := gen_random_uuid(); before int; after int;
begin
  insert into auth.users (id, email, created_at) values (u, 'push@notify.test', now() - interval '1 day');
  before := (public.job_check_push()->>'waiting')::int;
  insert into public.email_queue (user_id, kind, key, priority, status, created_at) values
    (u, 'grid_down', 'p:due',   0, 'sent', now() - interval '6 minutes'),   -- counts
    (u, 'grid_down', 'p:fresh', 0, 'sent', now() - interval '2 minutes'),   -- under 5 min
    (u, 'grid_down', 'p:old',   0, 'sent', now() - interval '2 hours'),     -- past push_claim's hour
    (u, 'welcome',   'p:mail',  1, 'sent', now() - interval '6 minutes');   -- not an alert
  insert into public.email_queue (user_id, kind, key, priority, status, created_at, pushed_at)
  values (u, 'grid_back', 'p:done', 0, 'sent', now() - interval '6 minutes', now());   -- handled
  after := (public.job_check_push()->>'waiting')::int;
  perform pg_temp.ok('P1 job_check_push counts only the due, unhandled alert', after - before = 1, format('%s -> %s', before, after));
end $$;

do $$
begin
  perform pg_temp.ok('G1 email_claim: service role only',
    has_function_privilege('service_role', 'public.email_claim(int, boolean, text)', 'execute')
    and not has_function_privilege('anon', 'public.email_claim(int, boolean, text)', 'execute')
    and not has_function_privilege('authenticated', 'public.email_claim(int, boolean, text)', 'execute'));
  perform pg_temp.ok('G2 job_check_push: service role only',
    has_function_privilege('service_role', 'public.job_check_push()', 'execute')
    and not has_function_privilege('anon', 'public.job_check_push()', 'execute')
    and not has_function_privilege('authenticated', 'public.job_check_push()', 'execute'));
  perform pg_temp.ok('G3 the two-argument email_claim is gone (no overload)',
    to_regprocedure('public.email_claim(int, boolean)') is null);
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r record; bad int := 0;
begin
  for r in select * from t_results order by n loop
    if r.pass then raise notice 'ok    %', r.label;
    else raise notice 'FAIL  %  (%)', r.label, r.detail; bad := bad + 1; end if;
  end loop;
  if bad > 0 then raise exception '% of % checks failed', bad, (select count(*) from t_results); end if;
  raise notice 'all % checks passed', (select count(*) from t_results);
end $$;
rollback;
