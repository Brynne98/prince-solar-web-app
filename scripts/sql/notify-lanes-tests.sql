-- SOLAR-645 step 2 (0257): email_claim lanes, job_check_push, push_claim's skip-locked
-- update, and billing.outbox_done's refund.
-- LOCAL database only, with every migration applied. One transaction, rolled back:
--   psql "$DB" -v ON_ERROR_STOP=1 -f scripts/sql/notify-lanes-tests.sql
-- Exit 0: every check passed. A failed check raises, so psql exits 3.

begin;
-- These checks drive push_claim (the old pop-up path). Since 0259 pop-ups go through the
-- outbox; put them back on the old path for this rolled-back transaction.
update msg.kinds set route = 'old' where channel = 'push';
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

-- push_claim (0257): "not an alert" rows are still marked, with the update that skips locked rows
do $$
declare u uuid := gen_random_uuid(); w bigint;
begin
  insert into auth.users (id, email, created_at) values (u, 'pushmark@notify.test', now() - interval '1 day');
  insert into public.email_queue (user_id, kind, key, priority) values (u, 'welcome', 'welcome:pushmark', 1) returning id into w;
  perform public.push_claim(200);
  perform pg_temp.ok('P2 push_claim still marks a welcome "not an alert"',
    (select push_skip from public.email_queue where id = w) = 'not an alert',
    (select push_skip from public.email_queue where id = w));
end $$;

-- billing outbox (0257): a 429 gives its try back and waits Retry-After; five tries without
-- a refund still fail
do $$
declare u uuid := gen_random_uuid(); a uuid; o1 bigint; o2 bigint; r record;
begin
  insert into auth.users (id, email, created_at) values (u, 'outbox@notify.test', now() - interval '1 day');
  insert into billing.accounts (user_id, market, created_at) values (u, 'ZA', now()) returning id into a;
  insert into billing.outbox (account, key, dedupe_key, not_before, expires_at, created_at, tries)
  values (a, 'receipt', 'lanes:o1', now(), now() + interval '1 day', now(), 5) returning id into o1;
  insert into billing.outbox (account, key, dedupe_key, not_before, expires_at, created_at, tries)
  values (a, 'receipt', 'lanes:o2', now(), now() + interval '1 day', now(), 5) returning id into o2;
  perform public.billing_jobs('outbox_done', jsonb_build_object('id', o1, 'ok', false, 'error', 'resend 429', 'retry_s', 7, 'refund', true));
  select * into r from billing.outbox where id = o1;
  perform pg_temp.ok('B1 429 at try 5: queued again, try given back, after Retry-After',
    r.status = 'queued' and r.tries = 4 and r.not_before between now() + interval '6 seconds' and now() + interval '8 seconds',
    format('%s %s %s', r.status, r.tries, r.not_before - now()));
  perform public.billing_jobs('outbox_done', jsonb_build_object('id', o2, 'ok', false, 'error', 'resend 500', 'retry_s', 300));
  select * into r from billing.outbox where id = o2;
  perform pg_temp.ok('B2 a 5xx at try 5 still fails', r.status = 'failed' and r.tries = 5, format('%s %s', r.status, r.tries));
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
