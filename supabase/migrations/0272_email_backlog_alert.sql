-- ============================================================================
-- 0272 — email backlog alert reads msg.outbox (SOLAR-667).
--
-- billing.alerts' outbox_backlog email line counted public.email_queue rows still 'queued'.
-- Since 0261-0265 those rows are events (status 'outbox') and emails wait in msg.outbox, so
-- the line never fired. It now counts msg.outbox email rows whose event was due over an hour
-- ago, ref 'msg_email'.
--
-- Body: 0246; only the lines marked 0268 change. No rows are written.
-- ============================================================================

create or replace function billing.alerts(p_at timestamptz default now())
returns jsonb language sql stable security definer set search_path = billing, pg_temp as $$
  select coalesce(jsonb_agg(a order by a->>'kind', a->>'ref'), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'attempt_pending', 'ref', pa.reference, 'since', pa.created_at, 'status', pa.status) a
      from billing.payment_attempts pa
     where pa.status in ('created', 'pending', 'unknown') and pa.created_at <= p_at - interval '1 hour'
    union all
    select jsonb_build_object('kind', 'refund_failed', 'ref', r.reference, 'tries', r.tries, 'error', r.last_error)
      from billing.refunds r where r.status = 'failed'
    union all
    -- 0272: emails wait in msg.outbox (both lanes). Late is from the event's due_at: a retry
    -- moves not_before on, so a row that keeps failing would never look an hour late. A "back"
    -- held for its "down" is not stuck; a stuck "down" counts on its own. Leased rows count.
    select jsonb_build_object('kind', 'outbox_backlog', 'ref', 'msg_email', 'waiting', count(*), 'oldest_due', min(q.due_at))
      from msg.outbox o join public.email_queue q on q.id = o.event_id
     where o.channel = 'email' and o.status = 'queued' and q.due_at <= p_at - interval '1 hour'
       and (q.pair_key is null or msg.email_down_state(q.user_id, q.pair_key) is distinct from 'wait')
    having count(*) > 0
    union all
    select jsonb_build_object('kind', 'outbox_backlog', 'ref', 'billing_outbox', 'waiting', count(*), 'oldest_due', min(o.not_before))
      from billing.outbox o where o.status = 'queued' and o.not_before <= p_at - interval '1 hour'
    having count(*) > 0
    union all
    select jsonb_build_object('kind', 'history_unprotected', 'ref', p.id::text, 'delete_at', ps->'delete_at')
      from billing.plants p cross join lateral billing.plant_state(p.id, p_at) ps
     where p.history_purged_at is null and ps->>'delete_at' is not null
       and (ps->>'delete_at')::timestamptz <= p_at - interval '1 hour'
       and not billing.payment_hold(p.id, p_at) and billing.has_history(p.id)
    union all
    -- history no seat holds, the last seat closed over an hour ago: the delete job missed it
    select jsonb_build_object('kind', 'history_unprotected', 'ref', p.id::text, 'closed_at', max(se.closed_at))
      from billing.plants p join billing.seats se on se.plant = p.id
     where p.history_purged_at is null
       and not exists (select 1 from billing.seats o where o.plant = p.id and o.closed_at is null)
     group by p.id
    having max(se.closed_at) <= p_at - interval '1 hour'
       and not billing.payment_hold(p.id, p_at) and billing.has_history(p.id)
    union all
    select jsonb_build_object('kind', 'many_switches', 'ref', e.account::text, 'switches', count(*))
      from billing.account_events e
     where e.kind = 'set_chosen_plants' and e.at > p_at - interval '7 days' and e.at <= p_at
       and e.before->'plants' is distinct from e.after->'plants'
     group by e.account having count(*) > 6
    union all
    select jsonb_build_object('kind', 'job_quiet', 'ref', j.job, 'last_run_at', h.last_run_at)
      from billing.switch_over so
     cross join (values ('delete', interval '30 minutes'), ('history', interval '10 minutes'),
                        ('billing-run', interval '26 hours')) j (job, quiet)
      left join billing.job_heartbeats h on h.job = j.job
     -- the delete job counts only once started (billing.start_delete_job, DEPLOY.md step 7)
     where (j.job <> 'delete' or h.job is not null)
       and coalesce(h.last_run_at, so.switched_at) <= p_at - j.quiet
  ) x
$$;
