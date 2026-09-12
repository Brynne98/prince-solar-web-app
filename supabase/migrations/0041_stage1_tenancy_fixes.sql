-- ============================================================================
-- 0041 — three things that break on the first outside customer (READINESS.md, Stage 1).
--
--   B1  The calibration plant (forecast fit, solar-cal cron, phone alerts) was
--       min(plant_id) over every user. SunSynk ids grow over time, so a customer
--       whose plant was commissioned before ours took the whole single-site
--       feature set over the minute they linked. Pinned in app_config now: set
--       once by the first link, never moved by later links or disconnects.
--
--   B2  Battery sign was one env var for the fleet. The firmware's sign differs
--       per install, so a customer with the other convention logged charging as
--       discharging forever. plant_config now carries it per plant, null meaning
--       "not known yet"; batt_sign_detect() works it out from the stored raw
--       power against SoC movement, flips the rows written under the wrong
--       assumption, and records the answer. A user can override in Settings.
--
--   B3  Two dashboard users on one plant: the polling account could flip minute
--       to minute (no ordering in plantsToPoll), and only the account that
--       happened to poll got last_ok_at. Every active account mapped to a plant
--       polled this minute is stamped now; the choice of account is made stable
--       in the poller (earliest linked).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- B1. Calibration plant
-- ---------------------------------------------------------------------------
insert into public.app_config (key, value, note)
select 'CALIBRATION_PLANT', min(plant_id), 'the one plant the single-site forecast/alerts are bound to; set by the first link, then fixed'
  from public.plant_users
having min(plant_id) is not null
on conflict (key) do nothing;

create or replace function public.calibration_plant()
returns bigint
language sql stable
set search_path = public, pg_temp
as $$ select public.cfg('CALIBRATION_PLANT')::bigint $$;

-- After a link: record which plants this user may see, and pin the calibration
-- plant if nothing is pinned yet (a fresh deployment's first plant).
create or replace function public.plant_users_upsert(p_user uuid, p_account uuid, p_rows jsonb)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  insert into public.plant_users (plant_id, user_id, account_id, plant_name)
  select (r->>'plant_id')::bigint, p_user, p_account, r->>'plant_name'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id, user_id) do update
    set account_id = excluded.account_id, plant_name = excluded.plant_name;

  insert into public.app_config (key, value, note)
  select 'CALIBRATION_PLANT', (r->>'plant_id')::bigint,
         'the one plant the single-site forecast/alerts are bound to; set by the first link, then fixed'
    from jsonb_array_elements(p_rows) r
   order by (r->>'plant_id')::bigint
   limit 1
  on conflict (key) do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- B2. Battery sign per plant
-- ---------------------------------------------------------------------------
alter table public.plant_config
  add column if not exists batt_positive_means text
    check (batt_positive_means in ('charging', 'discharging')),
  add column if not exists batt_sign_source text not null default 'default'
    check (batt_sign_source in ('default', 'detected', 'user')),
  add column if not exists batt_sign_updated_at timestamptz;

comment on column public.plant_config.batt_positive_means is
  'What a positive battery `power` means on this plant''s firmware. Null = not known yet; the poller uses its fleet default and batt_sign_detect() fills this in.';

-- The plant's setting for the poller, with the fleet default as the fallback.
-- p_default is what the poller would use when the plant has no answer yet.
create or replace function public.batt_sign_detect(p_plant bigint, p_default text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  cur      record;
  votes_c  int;
  votes_d  int;
  detected text;
  used     text;
  since    bigint;
  n_read   int := 0;
  n_agg    int := 0;
begin
  select batt_positive_means, batt_sign_source, batt_sign_updated_at into cur
    from public.plant_config where plant_id = p_plant;
  if cur.batt_sign_source = 'user' then
    return jsonb_build_object('plant', p_plant, 'skipped', 'user override');
  end if;

  -- Half an hour apart, same inverter, real (not carried) rows, battery working
  -- hard enough that SoC must move a whole percent, and power keeping one sign
  -- for the whole window. (A 26 kWh pack at 900 W moves ~0.6 %/10 min, which an
  -- integer SoC cannot show; 30 min is the shortest window that always can.)
  with r as (
    select sn, ts, batt_soc, batt_power_w,
           lag(batt_soc, 30) over w as soc0,
           lag(ts, 30)       over w as ts0,
           min(sign(batt_power_w)) over (partition by sn order by ts rows between 30 preceding and current row) as smin,
           max(sign(batt_power_w)) over (partition by sn order by ts rows between 30 preceding and current row) as smax
      from public.readings
     where plant_id = p_plant
       and ts > extract(epoch from now())::bigint - 86400
       and not carried
       and batt_soc between 1 and 100
       and batt_power_w is not null
    window w as (partition by sn order by ts)
  ),
  v as (
    select case when batt_power_w > 0 and batt_soc > soc0 then 'charging'
                when batt_power_w < 0 and batt_soc < soc0 then 'charging'
                when batt_power_w > 0 and batt_soc < soc0 then 'discharging'
                when batt_power_w < 0 and batt_soc > soc0 then 'discharging' end as vote
      from r
     where ts0 is not null and ts - ts0 between 1700 and 2100
       and abs(batt_power_w) >= 200 and smin = smax
       and abs(batt_soc - soc0) >= 1
  )
  select count(*) filter (where vote = 'charging'), count(*) filter (where vote = 'discharging')
    into votes_c, votes_d from v where vote is not null;

  if votes_c + votes_d < 6 then
    return jsonb_build_object('plant', p_plant, 'votes', jsonb_build_object('charging', votes_c, 'discharging', votes_d), 'decided', false);
  end if;
  if votes_c >= 9 * votes_d then detected := 'charging';
  elsif votes_d >= 9 * votes_c then detected := 'discharging';
  else
    return jsonb_build_object('plant', p_plant, 'votes', jsonb_build_object('charging', votes_c, 'discharging', votes_d), 'decided', false, 'reason', 'split');
  end if;

  -- What the poller has been assuming for rows since the last decision.
  used := coalesce(cur.batt_positive_means, p_default);
  since := coalesce(extract(epoch from cur.batt_sign_updated_at)::bigint, 0);

  if detected is distinct from used then
    update public.readings set batt_w = -batt_w
     where plant_id = p_plant and ts >= since and batt_w is not null;
    get diagnostics n_read = row_count;
    update public.agg_minute set batt_w = -batt_w
     where plant_id = p_plant and ts >= since and source = 'poller' and batt_w is not null;
    get diagnostics n_agg = row_count;
  end if;

  update public.plant_config
     set batt_positive_means = detected, batt_sign_source = 'detected', batt_sign_updated_at = now()
   where plant_id = p_plant;

  return jsonb_build_object('plant', p_plant, 'detected', detected, 'was', used,
                            'votes', jsonb_build_object('charging', votes_c, 'discharging', votes_d),
                            'flipped', jsonb_build_object('readings', n_read, 'agg', n_agg), 'decided', true);
end $$;
revoke all on function public.batt_sign_detect(bigint, text) from public, anon, authenticated;
grant execute on function public.batt_sign_detect(bigint, text) to service_role;

-- A user choosing Auto in Settings clears the answer so detection runs again;
-- choosing a value pins it. Keep the source column honest either way.
create or replace function public.plant_config_batt_sign_guard()
returns trigger language plpgsql as $$
begin
  if auth.uid() is not null and new.batt_positive_means is distinct from old.batt_positive_means then
    new.batt_sign_source := case when new.batt_positive_means is null then 'default' else 'user' end;
    new.batt_sign_updated_at := now();
  end if;
  return new;
end $$;
drop trigger if exists plant_config_batt_sign_guard on public.plant_config;
create trigger plant_config_batt_sign_guard before update on public.plant_config
  for each row execute function public.plant_config_batt_sign_guard();

-- ---------------------------------------------------------------------------
-- B3. Every account on a polled plant is stamped
-- ---------------------------------------------------------------------------
-- poll_commit: 0035's body, plus the last_ok_at fan-out at the end.
create or replace function public.poll_commit(
  p_account   uuid,
  p_ts        bigint,
  p_readings  jsonb,
  p_strings   jsonb,
  p_agg       jsonb,
  p_meta      jsonb,
  p_inverters jsonb,
  p_access    text,
  p_expires   bigint
)
returns jsonb
language plpgsql
security definer
set search_path = pg_temp
as $$
declare
  n_readings int := 0;
  n_strings  int := 0;
  gaps       bigint[] := '{}';
  plants     bigint[] := '{}';
  a          record;
  prev_ts    bigint;
begin
  if to_regclass('pg_temp._rd') is not null then drop table _rd; end if;
  if to_regclass('pg_temp._st') is not null then drop table _st; end if;

  create temp table _rd on commit drop as
    select * from jsonb_populate_recordset(null::public.readings, coalesce(p_readings, '[]'::jsonb))
     where plant_id is not null;
  delete from public.readings r using _rd where r.ts = p_ts and r.ts = _rd.ts and r.sn = _rd.sn;
  insert into public.readings select * from _rd;
  get diagnostics n_readings = row_count;

  create temp table _st on commit drop as
    select * from jsonb_populate_recordset(null::public.strings, coalesce(p_strings, '[]'::jsonb))
     where plant_id is not null;
  delete from public.strings s using _st where s.ts = p_ts and s.ts = _st.ts and s.sn = _st.sn and s.no = _st.no;
  insert into public.strings select * from _st;
  get diagnostics n_strings = row_count;

  for a in
    select (r->>'plant_id')::bigint as plant_id,
           nullif(r->>'pv_w',   '')::int as pv_w,
           nullif(r->>'load_w', '')::int as load_w,
           nullif(r->>'batt_w', '')::int as batt_w,
           nullif(r->>'grid_w', '')::int as grid_w,
           nullif(r->>'soc',    '')::int as soc
      from jsonb_array_elements(coalesce(p_agg, '[]'::jsonb)) r
     where r->>'plant_id' is not null
  loop
    plants := plants || a.plant_id;

    select max(ts) into prev_ts from public.agg_minute where plant_id = a.plant_id;
    if prev_ts is not null and p_ts - prev_ts > 90 then
      insert into private.gaps (plant_id, from_ts, to_ts) values (a.plant_id, prev_ts, p_ts)
      on conflict (plant_id, from_ts) do nothing;
      gaps := gaps || a.plant_id;
    end if;

    insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
    values (a.plant_id, p_ts, a.pv_w, a.load_w, a.batt_w, a.grid_w, a.soc, 'poller')
    on conflict (plant_id, ts) do nothing;
  end loop;

  perform public.meta_upsert(coalesce(p_meta, '[]'::jsonb));
  perform public.inverters_seed(coalesce(p_inverters, '[]'::jsonb));
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires,
         last_ok_at = now(), last_error = null
   where id = p_account;
  -- The other logins that can see these plants were served this minute too.
  update private.sunsynk_accounts s
     set last_ok_at = now()
   where s.status = 'active' and s.id <> p_account
     and exists (select 1 from public.plant_users pu where pu.account_id = s.id and pu.plant_id = any(plants));

  return jsonb_build_object(
    'readings', n_readings,
    'strings',  n_strings,
    'plants',   to_jsonb(plants),
    'gaps',     to_jsonb(gaps));
end;
$$;
revoke all on function public.poll_commit(uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb, text, bigint)
  from public, anon, authenticated;
grant execute on function public.poll_commit(uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb, text, bigint)
  to service_role;

-- ---------------------------------------------------------------------------
-- Batch cursors (READINESS P3): recover and sync-plant-energy keep the id of the
-- last plant they finished in app_config, so a run that runs out of budget does
-- not starve the same plants next time. service_role could read the table but
-- not write it.
-- ---------------------------------------------------------------------------
grant insert, update on public.app_config to service_role;
