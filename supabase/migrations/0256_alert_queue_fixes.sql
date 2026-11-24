-- ============================================================================
-- 0256 — three fixes on the old alert queue (SOLAR-645 step 1).
--
-- 1. push_claim checked only plant_users: a plant the owner no longer chose still
--    got a pop-up. It now needs an open seat, the test email_skip_unchosen uses (0252).
-- 2. email_sweep put "SunSynk is down" on the owner's oldest plant on a failing login.
--    When that plant was not chosen, the queue trigger dropped it and the owner heard
--    nothing. It now goes on the oldest plant that is read (private.plant_live, the
--    trigger's own test). "Back" follows its "down" through pair_key, as before.
-- 3. "No readings" waits 30 min from plant_alert_state.started_at, which only
--    plant_start_fill set, and nothing calls that since 0206. A plant read again (seat
--    chosen, plan paid again, grant, a choice that ends "choose your plants") could alert
--    at once on its old reading time. Every billing change that starts reading now sets it.
--
-- Bodies: push_claim 0232, email_sweep 0174, write_seats 0246, apply_payment 0254,
-- upgrade 0245, each patched in place (one line or block) and refused if it changed.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Phone alerts: plant not chosen, no pop-up.
-- ---------------------------------------------------------------------------
do $$
declare
  d text := pg_get_functiondef('public.push_claim(int)'::regprocedure);
  old text := $o$             then 'plant removed'
$o$;
begin
  if position(old in d) = 0 then raise exception 'push_claim changed since 0232: edit it by hand'; end if;
  d := replace(d, old, old || $n$           when q.plant_id is not null and not exists (
                  select 1 from billing.seats se join billing.accounts ba on ba.id = se.account
                   where ba.user_id = q.user_id and se.plant = q.plant_id and se.closed_at is null)
             then 'plant not chosen'                                              -- 0256
$n$);
  execute d;
end $$;

-- ---------------------------------------------------------------------------
-- 2. "SunSynk is down": the oldest plant the owner reads, on a failing login.
-- ---------------------------------------------------------------------------
do $$
declare
  d text := pg_get_functiondef('public.email_sweep()'::regprocedure);
  old text := $o$       and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes'
     order by pu.user_id, pu.linked_at$o$;
begin
  if position(old in d) = 0 then raise exception 'email_sweep changed since 0174: edit it by hand'; end if;
  d := replace(d, old, $n$       and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes'
       and private.plant_live(pu.user_id, pu.plant_id)                          -- 0256
     order by pu.user_id, pu.linked_at$n$);
  execute d;
end $$;

-- ---------------------------------------------------------------------------
-- 3. "No readings" counts 30 min from when a plant's reading starts again.
-- ---------------------------------------------------------------------------
-- The plants' reading starts at p_at: "No readings" waits 30 min from here.
create function billing.readings_start(p_plants bigint[], p_at timestamptz)
returns void language sql security definer set search_path = '' as $$
  insert into private.plant_alert_state (plant_id, started_at)
  select c.plant_id, extract(epoch from p_at)::bigint from public.plant_config c where c.plant_id = any (p_plants)
  on conflict (plant_id) do update
    set started_at = greatest(coalesce(private.plant_alert_state.started_at, 0), excluded.started_at)
$$;
revoke all on function billing.readings_start(bigint[], timestamptz) from public, anon, authenticated;

-- Is the account reading none of its plants at p_at: no plan or week running, or more
-- plants chosen than places (billing.reads_plant's account half).
create function billing.reading_held(p_account uuid, p_at timestamptz)
returns boolean language sql stable set search_path = billing, pg_temp as $$
  select coalesce((select not (st.state in ('trialing', 'active', 'past_due') and not st.must_choose)
                     from billing.account_status(p_account, p_at) st), true)
$$;
revoke all on function billing.reading_held(uuid, timestamptz) from public, anon, authenticated;

-- An account whose reading was held reads again: every open seat starts now.
create function billing.readings_resume(p_account uuid, p_at timestamptz)
returns void language sql set search_path = billing, pg_temp as $$
  select billing.readings_start(array(select plant from billing.seats where account = p_account and closed_at is null), p_at)
$$;
revoke all on function billing.readings_resume(uuid, timestamptz) from public, anon, authenticated;

-- 0246's write_seats, plus: new seats start reading; when the account read nothing before
-- (free week starting, plants chosen to end "choose your plants"), every chosen plant does.
create or replace function billing.write_seats(p_account uuid, p_want bigint[], p_at timestamptz, p_reason text default 'switched',
                                               p_counts boolean default false)
returns void language plpgsql set search_path = billing, pg_temp as $$
declare had bigint[]; held boolean;
begin
  held := billing.reading_held(p_account, p_at);                                  -- 0256
  had := array(select plant from billing.seats where account = p_account and closed_at is null order by 1);
  update billing.seats set closed_at = p_at, close_reason = p_reason
   where account = p_account and closed_at is null and plant <> all (p_want);
  insert into billing.seats (account, plant, chosen_at)
  select p_account, x, p_at from unnest(p_want) x where x <> all (had);
  update billing.plants set trial_used_at = coalesce(trial_used_at, p_at),
                            trial_used_by = coalesce(trial_used_by, p_account)
   where id = any (p_want) and id <> all (had) and (trial_used_at is null or trial_used_by is null);
  update billing.plants set version = version + 1
   where id = any (p_want || had) and not (id = any (p_want) and id = any (had));
  update billing.history_fetches set status = 'dropped', drop_reason = 'switched_out', finished_at = p_at, claimed_until = null
   where account = p_account and status in ('queued', 'running') and plant = any (had) and plant <> all (p_want);
  -- a seat opening (or a plan restarting) on a deleted plant: it gathers history again. The
  -- caller holds the plant locks, so no write path has to touch the row.
  update billing.plants set history_purged_at = null
   where id = any (p_want) and history_purged_at is not null;
  -- a plant switched out that no account keeps is deleted now, under its lock, so the
  -- pop-up's "deleted now" holds even if the owner switches straight back
  perform billing.purge_now(x, p_at) from unnest(had) x where x <> all (p_want);
  perform billing.request_history(p_account, array(select x from unnest(p_want) x where x <> all (had)), p_at, p_counts);
  perform billing.readings_start(case when held then p_want                       -- 0256
                                      else array(select x from unnest(p_want) x where x <> all (had)) end, p_at);
end $$;

-- A paid bill that ends a hold (a plan paid again after it ended, a renewal revived, an
-- upgrade with enough places): the kept plants read again. Their seats stayed open.
do $$
declare
  d text := pg_get_functiondef('billing.apply_payment(text, jsonb, timestamptz)'::regprocedure);
  old text := $o$    case inv.kind
      when 'purchase' then perform billing.apply_purchase(inv, paid);
      when 'renewal' then perform billing.apply_renewal(inv, paid);
      when 'upgrade' then perform billing.apply_upgrade(inv, paid);
      else rid := billing.refund_due(att.id, att.reference, a.id, att.currency, 'card_check', p_at);
    end case;
$o$;
begin
  if position(old in d) = 0 then raise exception 'apply_payment changed since 0254: edit it by hand'; end if;
  d := replace(d, old, $n$    declare held boolean := billing.reading_held(a.id, p_at);                   -- 0256
    begin
    case inv.kind
      when 'purchase' then perform billing.apply_purchase(inv, paid);
      when 'renewal' then perform billing.apply_renewal(inv, paid);
      when 'upgrade' then perform billing.apply_upgrade(inv, paid);
      else rid := billing.refund_due(att.id, att.reference, a.id, att.currency, 'card_check', p_at);
    end case;
    if held and inv.kind in ('purchase', 'renewal', 'upgrade') and not billing.reading_held(a.id, p_at) then
      perform billing.readings_resume(a.id, p_at);
    end if;
    end;
$n$);
  execute d;
end $$;

-- An upgrade with nothing to pay applies at once: the same as a paid one.
do $$
declare
  d text := pg_get_functiondef('billing.upgrade(uuid, text, int, bigint[], timestamptz, text)'::regprocedure);
  old text := $o$    perform billing.apply_upgrade(inv, p_at);
$o$;
begin
  if position(old in d) = 0 then raise exception 'upgrade changed since 0245: edit it by hand'; end if;
  d := replace(d, old, $n$    declare held boolean := billing.reading_held(p_account, p_at);              -- 0256
    begin
      perform billing.apply_upgrade(inv, p_at);
      if held and not billing.reading_held(p_account, p_at) then perform billing.readings_resume(p_account, p_at); end if;
    end;
$n$);
  execute d;
end $$;

-- A grant that starts reading (added, or made longer after it ended): the account's
-- chosen plants start when it does. Before the row is written, so the status is without it.
create function billing.grant_readings_start()
returns trigger language plpgsql set search_path = billing, pg_temp as $$
declare t timestamptz := greatest(now(), new.starts_at);
begin
  if (new.ends_at is null or new.ends_at > t) and billing.reading_held(new.account, t) then
    perform billing.readings_resume(new.account, t);
  end if;
  return new;
end $$;
create trigger grants_readings_start before insert or update of starts_at, ends_at, places on billing.grants
  for each row execute function billing.grant_readings_start();
