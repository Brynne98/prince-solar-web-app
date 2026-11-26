-- SOLAR-679 F13 (0281): an address that bounced for good, complained or is on the mail
-- service's block list gets no more mail. mail_block records it; msg_email_take (email_guard)
-- and billing.outbox_take drop every later email to it, a final state.
-- LOCAL database only, with every migration applied. One transaction, rolled back:
--   psql "$DB" -v ON_ERROR_STOP=1 -f scripts/sql/mail-blocked-tests.sql
-- Exit 0: every check passed. A failed check raises, so psql exits 3.

begin;
set client_min_messages = notice;

create temp table t_results (n serial, label text, pass boolean, detail text);
create function pg_temp.ok(p_label text, p_cond boolean, p_detail text default null)
returns void language sql as $$
  insert into t_results (label, pass, detail) values (p_label, coalesce(p_cond, false), p_detail)
$$;
create function pg_temp.user(p_email text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, created_at) values (u, p_email, now() - interval '1 day');
  return u;
end $$;

-- M: the record
do $$
declare n int; r private.mail_blocked;
begin
  n := public.mail_block(array[' Gone@MailBlock.test ', '', null], 'bounced', 'General: mailbox unavailable');
  select * into r from private.mail_blocked where email = 'gone@mailblock.test';
  perform pg_temp.ok('M1 one address, lower case, trimmed; blanks skipped', n = 1 and r.reason = 'bounced' and r.events = 1,
    format('%s %s', n, row_to_json(r)));
  perform public.mail_block(array['gone@mailblock.test'], 'complained', null);
  select * into r from private.mail_blocked where email = 'gone@mailblock.test';
  perform pg_temp.ok('M2 the same address again (a resent call): one row, counted, latest reason',
    r.events = 2 and r.reason = 'complained' and (select count(*) from private.mail_blocked where email = 'gone@mailblock.test') = 1);
  perform pg_temp.ok('M3 mail_blocked: any case', private.mail_blocked('GONE@mailblock.test') and not private.mail_blocked('other@mailblock.test')
    and not private.mail_blocked(null));
  begin
    perform public.mail_block(array['x@mailblock.test'], 'soft', null);
    perform pg_temp.ok('M4 an unknown reason is refused', false);
  exception when check_violation then perform pg_temp.ok('M4 an unknown reason is refused', true);
  end;
end $$;

-- E: message outbox emails (welcome, bulk lane; alerts use the same email_guard)
do $$
declare gone uuid := pg_temp.user('Gone@MailBlock.test'); fine uuid := pg_temp.user('fine@mailblock.test');
        qg bigint; qf bigint; og msg.outbox; taken bigint[];
begin
  insert into public.email_queue (user_id, kind, key, data, priority, created_at, due_at)
  values (gone, 'welcome', 'mb:gone', '{}', 1, now(), now()) returning id into qg;
  insert into public.email_queue (user_id, kind, key, data, priority, created_at, due_at)
  values (fine, 'welcome', 'mb:fine', '{}', 1, now(), now()) returning id into qf;
  taken := array(select event_id from public.msg_email_take(1000, 'bulk'));
  select * into og from msg.outbox where event_id = qg and channel = 'email';
  perform pg_temp.ok('E1 blocked address: not taken, dropped "address blocked", final',
    not qg = any(taken) and og.status = 'dropped' and og.drop_reason = 'address blocked' and og.done_at is not null,
    row_to_json(og)::text);
  perform pg_temp.ok('E2 another address: taken', qf = any(taken));
  perform pg_temp.ok('E3 not handed out again', not exists (select 1 from public.msg_email_take(1000, 'bulk') t where t.event_id = qg));
end $$;

-- B: billing outbox emails
-- Each kind's own guard (billing-state-tests) is stubbed to pass inside this rolled-back
-- transaction, so the check here is the address alone.
create or replace function billing.outbox_guard(o billing.outbox, p_at timestamptz) returns text
language sql stable as $$ select null::text $$;
do $$
declare gone uuid := pg_temp.user('complained@mailblock.test'); fine uuid := pg_temp.user('paid@mailblock.test');
        ag uuid; af uuid; og bigint; ofine bigint; w jsonb; r billing.outbox;
begin
  perform public.mail_block(array['complained@mailblock.test'], 'complained', null);
  insert into billing.accounts (user_id, market, created_at) values (gone, 'ZA', now()) returning id into ag;
  insert into billing.accounts (user_id, market, created_at) values (fine, 'ZA', now()) returning id into af;
  insert into billing.outbox (account, key, dedupe_key, not_before, expires_at, created_at)
  values (ag, 'receipt', 'mb:o1', now(), now() + interval '1 day', now()) returning id into og;
  insert into billing.outbox (account, key, dedupe_key, not_before, expires_at, created_at)
  values (af, 'receipt', 'mb:o2', now(), now() + interval '1 day', now()) returning id into ofine;
  w := billing.outbox_take(5000, now());
  select * into r from billing.outbox where id = og;
  perform pg_temp.ok('B1 blocked address: not handed out, dropped "address blocked", no try counted',
    not exists (select 1 from jsonb_array_elements(w) x where (x->>'id')::bigint = og)
    and r.status = 'dropped' and r.drop_reason = 'address blocked' and r.tries = 0, row_to_json(r)::text);
  perform pg_temp.ok('B2 another address: handed out',
    exists (select 1 from jsonb_array_elements(w) x where (x->>'id')::bigint = ofine));
end $$;

-- G: who may call
do $$
begin
  perform pg_temp.ok('G1 mail_block: service role only',
    has_function_privilege('service_role', 'public.mail_block(text[], text, text)', 'execute')
    and not has_function_privilege('anon', 'public.mail_block(text[], text, text)', 'execute')
    and not has_function_privilege('authenticated', 'public.mail_block(text[], text, text)', 'execute'));
  perform pg_temp.ok('G2 the list: no app access',
    not has_table_privilege('anon', 'private.mail_blocked', 'select')
    and not has_table_privilege('authenticated', 'private.mail_blocked', 'select'));
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
