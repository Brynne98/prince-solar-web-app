-- SOLAR-451 (0177): the share login stopping or coming back mails each owner once.
--   psql "$DB_URL" -f scripts/sql/verify-0177.sql      (local database only; rolled back)
-- Run before 0177 is applied, prepend the migration inside the transaction:
--   (echo 'begin;'; cat supabase/migrations/0177_share_login_down.sql; sed 1,/^begin/d scripts/sql/verify-0177.sql) | psql "$DB_URL"
-- Exit code decides: any wrong case raises.
\set QUIET on
\set ON_ERROR_STOP on
\o /dev/null
begin;

create function pg_temp.eq(label text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  if got is distinct from want then raise exception 'FAIL %: got %, want %', label, got, want; end if;
  raise notice 'PASS  %', label;
end $$;

-- a: company user (owns the share login); b: owner of two shared plants; c: one plant;
-- d: a paused plant; e: a plant whose share was removed; f: own login, not shared
insert into auth.users (id, email)
  select ('00000000-0000-0000-0000-00000000451' || x)::uuid, x || '@t.test' from unnest(array['a', 'b', 'c', 'd', 'e', 'f']) x;
insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind, last_ok_at)
values ('00000000-0000-0000-0000-00000451acc0', '00000000-0000-0000-0000-00000000451a', 'share451@t.test', 'active', 'share', now() - interval '10 minutes'),
       ('00000000-0000-0000-0000-00000451accf', '00000000-0000-0000-0000-00000000451f', 'own451', 'active', 'login', now());
-- b is on Free here; the plan limit would pause Cabin, which is not what is tested
alter table public.plant_users disable trigger plant_users_plan_limit;
insert into public.plant_users (plant_id, user_id, account_id, plant_name, via_share, paused, share_gone_at, linked_at)
values (945101, '00000000-0000-0000-0000-00000000451b', '00000000-0000-0000-0000-00000451acc0', 'Home', true, false, null, now() - interval '2 days'),
       (945102, '00000000-0000-0000-0000-00000000451b', '00000000-0000-0000-0000-00000451acc0', 'Cabin', true, false, null, now() - interval '1 day'),
       (945103, '00000000-0000-0000-0000-00000000451c', '00000000-0000-0000-0000-00000451acc0', null, true, false, null, now()),
       (945104, '00000000-0000-0000-0000-00000000451d', '00000000-0000-0000-0000-00000451acc0', 'Paused', true, true, null, now()),
       (945105, '00000000-0000-0000-0000-00000000451e', '00000000-0000-0000-0000-00000451acc0', 'Gone', true, false, now(), now()),
       (945106, '00000000-0000-0000-0000-00000000451f', '00000000-0000-0000-0000-00000451accf', 'Own', false, false, null, now());

-- ---- Stops ------------------------------------------------------------------------------
select public.account_mark('00000000-0000-0000-0000-00000451acc0', 'needs_relink', 'refused');
select pg_temp.eq('stop: one email per owner of a running shared plant (b, c)',
  (select array_agg(right(user_id::text, 1) order by user_id) from public.email_queue where kind = 'share_down'), array['b', 'c']);
select pg_temp.eq('stop: owner b gets one email naming both plants, oldest first, on the oldest plant',
  (select data->'plants' || jsonb_build_array(plant_id) from public.email_queue where kind = 'share_down' and user_id = '00000000-0000-0000-0000-00000000451b'),
  '["Home", "Cabin", 945101]'::jsonb);
select pg_temp.eq('stop: a plant with no name reads Plant <id>',
  (select data->'plants' from public.email_queue where kind = 'share_down' and user_id = '00000000-0000-0000-0000-00000000451c'),
  '["Plant 945103"]'::jsonb);
select pg_temp.eq('stop: since is the last good poll',
  (select (data->>'since')::bigint from public.email_queue where kind = 'share_down' and user_id = '00000000-0000-0000-0000-00000000451b'),
  (select extract(epoch from last_ok_at)::bigint from private.sunsynk_accounts where id = '00000000-0000-0000-0000-00000451acc0'));
select pg_temp.eq('stop: the company user gets no sign-in email',
  (select count(*) from public.email_queue where user_id = '00000000-0000-0000-0000-00000000451a'), 0::bigint);
select pg_temp.eq('stop: these are plain emails, not alerts', private.is_alert('share_down') or private.is_alert('share_back'), false);

-- a second stop while already stopped sends nothing
select public.account_mark('00000000-0000-0000-0000-00000451acc0', 'needs_relink', 'refused again');
select pg_temp.eq('stop again: nothing new', (select count(*) from public.email_queue where kind = 'share_down'), 2::bigint);

-- ---- Retry timing ---------------------------------------------------------------------
select pg_temp.eq('retry: not due within the hour of the last try', public.share_retry_due(), null::uuid);
update private.sunsynk_login_events set at = now() - interval '2 hours' where account_id = '00000000-0000-0000-0000-00000451acc0';
select pg_temp.eq('retry: due an hour on', public.share_retry_due(), '00000000-0000-0000-0000-00000451acc0'::uuid);
-- a failed retry is logged as another stop: not due again for an hour, and no new email
select public.account_mark('00000000-0000-0000-0000-00000451acc0', 'needs_relink', 'retry refused');
select pg_temp.eq('retry: a failed try restarts the hour', public.share_retry_due(), null::uuid);
select pg_temp.eq('retry: a failed try sends nothing', (select count(*) from public.email_queue where kind = 'share_down'), 2::bigint);

-- ---- Back -------------------------------------------------------------------------------
-- what shareAccount() does after a good sign-in
select public.share_account_set('00000000-0000-0000-0000-00000000451a', 'share451@t.test', 'tok', 0);
select pg_temp.eq('back: one email per owner told it stopped',
  (select array_agg(right(user_id::text, 1) order by user_id) from public.email_queue where kind = 'share_back'), array['b', 'c']);
select pg_temp.eq('back: paired with its stop, carries since and plants',
  (select (b.pair_key = d.key) and (b.data->'since' = d.data->'since') and (b.data->'plants' = d.data->'plants') and b.data ? 'at'
     from public.email_queue b join public.email_queue d on d.user_id = b.user_id and d.kind = 'share_down'
    where b.kind = 'share_back' and b.user_id = '00000000-0000-0000-0000-00000000451b'), true);
select pg_temp.eq('back: the company user still gets nothing',
  (select count(*) from public.email_queue where user_id = '00000000-0000-0000-0000-00000000451a'), 0::bigint);

-- ---- Own logins: unchanged (0164) --------------------------------------------------------
select public.account_mark('00000000-0000-0000-0000-00000451accf', 'needs_relink', 'refused');
select pg_temp.eq('own login: still one Sign in again email to its user',
  (select count(*) from public.email_queue where kind = 'needs_relink' and user_id = '00000000-0000-0000-0000-00000000451f'), 1::bigint);

\o
\echo verify-0177: all PASS
rollback;
