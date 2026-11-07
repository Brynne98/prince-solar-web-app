-- verify-switches: every notification switch off and on (SOLAR-402). Local stack only; one
-- transaction, rolled back. Prints email / pop-up / in-app list per kind.
-- psql "$LOCAL_DB_URL" -X -q -f scripts/sql/verify-switches.sql
\set ON_ERROR_STOP 1
begin;
-- nothing older than this test is due
update public.email_queue set status = 'skipped' where status = 'queued';
update public.email_queue set pushed_at = now(), push_skip = 'test' where pushed_at is null;

-- U_off: every switch off (email and pop-up). U_on: every switch on. Each has one plant,
-- one SunSynk login and one browser with pop-ups.
insert into auth.users (id, email, email_confirmed_at, aud, role) values
  ('00000000-0000-0000-0000-00000000c0ff', 'off@example.test', now(), 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-00000000c0aa', 'on@example.test',  now(), 'authenticated', 'authenticated');
insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values
  ('00000000-0000-0000-0000-0000000acc0f', '00000000-0000-0000-0000-00000000c0ff', 'off@mock'),
  ('00000000-0000-0000-0000-0000000acc0a', '00000000-0000-0000-0000-00000000c0aa', 'on@mock');
insert into public.plant_users (plant_id, user_id, plant_name, account_id) values
  (990301, '00000000-0000-0000-0000-00000000c0ff', 'Off plant', '00000000-0000-0000-0000-0000000acc0f'),
  (990302, '00000000-0000-0000-0000-00000000c0aa', 'On plant',  '00000000-0000-0000-0000-0000000acc0a');
insert into public.push_subs (user_id, endpoint, p256dh, auth) values
  ('00000000-0000-0000-0000-00000000c0ff', 'https://push.test/off', 'k', 'a'),
  ('00000000-0000-0000-0000-00000000c0aa', 'https://push.test/on',  'k', 'a');
insert into public.email_prefs (user_id, weekly, monthly, yearly, grid, battery, panels, readings, sunsynk) values
  ('00000000-0000-0000-0000-00000000c0ff', false, false, false, false, false, false, false, false),
  ('00000000-0000-0000-0000-00000000c0aa', true, true, true, true, true, true, true, true);
insert into public.push_prefs (user_id, grid, battery, panels, readings, sunsynk) values
  ('00000000-0000-0000-0000-00000000c0ff', false, false, false, false, false),
  ('00000000-0000-0000-0000-00000000c0aa', true, true, true, true, true);

-- The events, on both plants, the way the poller and the login check write them.
do $$
declare p bigint; s bigint := extract(epoch from now())::bigint - 600;
begin
  foreach p in array array[990301, 990302] loop
    perform private.email_enqueue_plant(p, 'grid_down', 'grid_down:' || p || ':t', jsonb_build_object('since', s, 'chargePct', 62));
    perform private.email_enqueue_plant(p, 'batt_hot', 'batt_hot:' || p || ':t', jsonb_build_object('at', s, 'tempC', 47));
    perform private.email_enqueue_plant(p, 'bank_drift', 'bank_drift:' || p || ':t', jsonb_build_object('since', s, 'banks',
      jsonb_build_array(jsonb_build_object('name', 'Inverter 1', 'chargePct', 72), jsonb_build_object('name', 'Inverter 2', 'chargePct', 60))));
    perform private.email_enqueue_plant(p, 'string_dead', 'string_dead:' || p || ':t', jsonb_build_object('since', s, 'inverter', 'Inverter 1', 'string', 'String 2'));
    perform private.email_enqueue_plant(p, 'logger_stale', 'logger_stale:' || p || ':t', jsonb_build_object('since', s));
    perform private.email_enqueue_plant(p, 'sunsynk_down', 'sunsynk_down:' || p || ':t', jsonb_build_object('since', s));
  end loop;
end $$;
insert into public.email_queue (user_id, plant_id, kind, key, data)
select u, p, k, k || ':' || p || ':t', jsonb_build_object('from', '2026-10-26', 'to', '2026-11-01')
  from (values ('00000000-0000-0000-0000-00000000c0ff'::uuid, 990301::bigint), ('00000000-0000-0000-0000-00000000c0aa', 990302)) v(u, p),
       unnest(array['report_week', 'report_month', 'report_year']) k;
-- the login dies (no switch)
update private.sunsynk_accounts set status = 'needs_relink' where id in ('00000000-0000-0000-0000-0000000acc0f', '00000000-0000-0000-0000-0000000acc0a');
-- every row due now
update public.email_queue set due_at = now() where user_id in ('00000000-0000-0000-0000-00000000c0ff', '00000000-0000-0000-0000-00000000c0aa');

-- The senders run.
create temp table sent_email as select id from public.email_claim(500, false);
create temp table sent_push as select id from public.push_claim(500);

-- What each user sees on the Notifications page.
create temp table listed (uid uuid, kind text);
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000c0ff', 'role', 'authenticated')::text, true);
insert into listed select '00000000-0000-0000-0000-00000000c0ff', i->>'kind' from jsonb_array_elements(public.api_alerts()->'items') i;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000c0aa', 'role', 'authenticated')::text, true);
insert into listed select '00000000-0000-0000-0000-00000000c0aa', i->>'kind' from jsonb_array_elements(public.api_alerts()->'items') i;
select set_config('request.jwt.claims', '', true);

\pset format aligned
\pset footer off
select coalesce(private.email_switch(q.kind), '(none)') as switch, q.kind,
       case when q.user_id = '00000000-0000-0000-0000-00000000c0ff' then 'off' else 'on' end as set_to,
       case when q.id in (select id from sent_email) then 'sent' else 'not sent: ' || coalesce(q.last_error, q.status) end as email,
       case when q.id in (select id from sent_push) then 'sent' else 'not sent: ' || coalesce(q.push_skip, '-') end as popup,
       case when exists (select 1 from listed l where l.uid = q.user_id and l.kind = q.kind) then 'listed' else 'not listed' end as in_app
  from public.email_queue q
 where q.user_id in ('00000000-0000-0000-0000-00000000c0ff', '00000000-0000-0000-0000-00000000c0aa')
 order by 1, 2, 3 desc;
rollback;
