-- ============================================================================
-- 0272 — "Add your plant when you're ready" 7 days after sign-up (SOLAR-474).
--
-- Welcome and need a hand (+24 h, 0147) were all an account with no plant got. This queues a
-- third email with them when the address is confirmed, due 7 days later. unique (user_id, key):
-- one per account; accounts confirmed before this get none. Lane bulk, 2 days, from hello@,
-- no switch (as welcome and need a hand). The guard drops it if the account has any SunSynk
-- login by then (a disconnected or dead one too) or any plant, a claimed shared plant included:
-- a share claim adds a plant but no login of the account's own.
--
-- Both functions get one line put in, not rewritten, so another branch editing them keeps its
-- lines (the 0252 way). Each stops if the line it hangs on has changed.
-- ============================================================================

insert into msg.kinds (kind, channel, route, lane, ttl)
values ('add_plant_reminder', 'email', 'outbox', 'bulk', interval '2 days');

do $$
declare
  d text := pg_get_functiondef('private.email_on_confirm()'::regprocedure);
  anchor text := $a$values (new.id, 'need_a_hand', 'need_a_hand', 1, now() + interval '24 hours')
    on conflict do nothing;$a$;
begin
  if position(anchor in d) = 0 then
    raise exception 'email_on_confirm changed since 0147: edit it by hand';
  end if;
  execute replace(d, anchor, anchor || $n$
    insert into public.email_queue (user_id, kind, key, priority, due_at)
    values (new.id, 'add_plant_reminder', 'add_plant_reminder', 1, now() + interval '7 days')
    on conflict do nothing;$n$);
end $$;

do $$
declare
  d text := pg_get_functiondef('msg.email_guard(msg.outbox)'::regprocedure);
  anchor text := $a$                and not private.pick_waiting(q.user_id)
             then 'login added'$a$;
begin
  if position(anchor in d) = 0 then
    raise exception 'email_guard changed since 0263: edit it by hand';
  end if;
  execute replace(d, anchor, anchor || $n$
           when q.kind = 'add_plant_reminder'
                and (exists (select 1 from private.sunsynk_accounts a where a.user_id = q.user_id)
                     or exists (select 1 from public.plant_users pu where pu.user_id = q.user_id))
             then 'plant added'$n$);
end $$;
