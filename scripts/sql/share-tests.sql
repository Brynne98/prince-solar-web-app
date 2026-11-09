-- Shared plant tests (SOLAR-310, 0172): claim, taken, share removed and back, takeover,
-- Account listing and removal. Needs the local database at the latest migration and the
-- local seed users. Runs inside one transaction, then rolls it all back.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/sql/share-tests.sql
-- Exit code decides: any wrong case raises.
\set ON_ERROR_STOP 1
begin;
create temp table t(step text, got text, want text);
do $$
declare
  a uuid := '5def03da-7ce5-4626-a836-d2d711f8831a';  -- export@
  b uuid := '259a4d2e-ab10-4571-8004-5cec4fa07781';  -- nobatt@
  co uuid := 'bc4ef05b-7dec-48f9-9606-1dc6067b2876'; -- stands in for the company user
  acc uuid; r text; x bigint := 990001; j jsonb; n int;
begin
  -- the share login already linked here, if any (only one may exist), else a stand-in
  acc := coalesce((select id from private.sunsynk_accounts where kind = 'share'),
                  public.share_account_set(co, 'share@local.test', 'tok', 9999999999999));
  insert into t values ('kind', (select kind from private.sunsynk_accounts where id = acc), 'share');
  insert into t values ('A claims', public.share_claim(a, acc, x, 'Shared One'), 'claimed');
  insert into t values ('B claims same', public.share_claim(b, acc, x, 'Shared One'), 'taken');
  insert into t values ('A again', public.share_claim(a, acc, x, 'Shared One'), 'yours');
  insert into t values ('B claims password plant 5001', public.share_claim(b, acc, 5001, 'x'),
    case when exists (select 1 from public.plant_users where plant_id = 5001 and user_id <> b) then 'taken' else 'claimed' end);
  insert into t values ('poll_jobs has x', (select count(*)::text from public.poll_jobs(0, 1) where plant_id = x), '1');
  j := public.share_sync(acc, array[]::bigint[]);
  insert into t values ('first miss', (select (share_missing_at is not null)::text from public.plant_users where plant_id = x and user_id = a), 'true');
  insert into t values ('still polled after one miss', (select count(*)::text from public.poll_jobs(0, 1) where plant_id = x), '1');
  update public.plant_users set share_missing_at = now() - interval '1 hour' where plant_id = x;
  j := public.share_sync(acc, array[]::bigint[]);
  insert into t values ('second miss stops', (select (share_gone_at is not null)::text from public.plant_users where plant_id = x and user_id = a), 'true');
  insert into t values ('email queued', (select count(*)::text from public.email_queue where kind = 'share_removed' and plant_id = x and user_id = a), '1');
  insert into t values ('not polled', (select count(*)::text from public.poll_jobs(0, 1) where plant_id = x), '0');
  j := public.share_sync(acc, array[x]);
  insert into t values ('re-shared waits for Check', (select (share_gone_at is null)::text from public.plant_users where plant_id = x and user_id = a), 'false');
  insert into t values ('A Check restarts it', public.share_claim(a, acc, x, 'Shared One'), 'claimed');
  insert into t values ('A live again', (select (share_gone_at is null)::text from public.plant_users where plant_id = x and user_id = a), 'true');
  -- lapse again, then B takes it over
  update public.plant_users set share_gone_at = now() where plant_id = x and user_id = a;
  insert into t values ('B claims lapsed', public.share_claim(b, acc, x, 'Shared One'), 'claimed');
  insert into t values ('A row gone', (select count(*)::text from public.plant_users where plant_id = x and user_id = a), '0');
  insert into t values ('one live claim', (select count(*)::text from public.plant_users where plant_id = x and via_share and share_gone_at is null), '1');
  -- B sees it in api_link_status, as the share kind, without the company user's other rows
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  insert into t values ('B link status kind', (select kind from public.api_link_status() where account_id = acc), 'share');
  insert into t values ('B link status plants', (select jsonb_array_length(plants)::text from public.api_link_status() where account_id = acc), '1');
  j := public.api_link_remove(acc);
  insert into t values ('B removed', (select count(*)::text from public.plant_users where plant_id = x), '0');
  insert into t values ('share login kept', (select count(*)::text from private.sunsynk_accounts where id = acc), '1');
  -- A (no claim) can't remove the share login
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  begin
    perform public.api_link_remove(acc);
    insert into t values ('A blocked', 'no', 'yes');
  exception when others then insert into t values ('A blocked', 'yes', 'yes');
  end;
end $$;
select step, got, want, case when got is not distinct from want then 'ok' else 'FAIL' end from t;
do $$ begin
  if exists (select 1 from t where got is distinct from want) then raise exception 'share tests failed'; end if;
end $$;
rollback;
