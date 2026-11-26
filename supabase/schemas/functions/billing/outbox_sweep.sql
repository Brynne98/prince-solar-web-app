CREATE OR REPLACE FUNCTION billing.outbox_sweep(p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  a record;
  st billing.status;
  s jsonb;
  n int := 0;
  kept timestamptz;
  d int;
begin
  if not billing.is_live() then return jsonb_build_object('live', false); end if;
  for a in select id from billing.accounts loop
    st := billing.account_status(a.id, p_at);
    if st.state = 'trialing' and st.trial_ends_at - p_at <= interval '2 days' then
      perform billing.outbox_put(a.id, 'trial_ends_soon', null, extract(epoch from st.trial_ends_at)::bigint::text,
        'trial_ends_soon:' || a.id || ':' || extract(epoch from st.trial_ends_at)::bigint, p_at, st.trial_ends_at, p_at);
    elsif st.state = 'ended' and st.access_ended_at is not null then
      if st.access_ended_at = st.trial_ends_at and p_at < st.trial_ends_at + interval '2 days'
         and not exists (select 1 from billing.subscriptions x where x.account = a.id) then
        perform billing.outbox_put(a.id, 'trial_ended', null, extract(epoch from st.trial_ends_at)::bigint::text,
          'trial_ended:' || a.id || ':' || extract(epoch from st.trial_ends_at)::bigint, p_at, p_at + interval '2 days', p_at);
      end if;
      foreach d in array array[14, 27] loop
        if p_at >= st.access_ended_at + make_interval(days => d) and p_at < st.access_ended_at + make_interval(days => d + 2) then
          s := billing.account_state(a.id, p_at);
          kept := (select min((p->>'delete_at')::timestamptz) from jsonb_array_elements(s->'plants') p
                    where (p->>'chosen')::boolean and (p->>'delete_at')::timestamptz > p_at);
          if kept is not null then
            perform billing.outbox_put(a.id, 'history_delete_soon', null, extract(epoch from kept)::bigint::text,
              'history_delete_soon:' || d || ':' || a.id || ':' || extract(epoch from st.access_ended_at)::bigint,
              p_at, kept, p_at);
          end if;
        end if;
      end loop;
    elsif st.state = 'past_due' then
      perform billing.payment_reminder_put(a.id, st, p_at);                                    -- 0276
    elsif st.state = 'active' and st.sub is not null and st.cancel_at is null then
      if st.interval = 'year' and st.period_end - p_at <= interval '7 days' and st.period_end > p_at then
        perform billing.outbox_put(a.id, 'renewal_soon', null, st.sub::text,
          'renewal_soon:' || st.sub || ':' || extract(epoch from st.period_end)::bigint, p_at, st.period_end, p_at);
      end if;
      if st.period_end - p_at <= interval '30 days' and (billing.money_state(a.id, p_at, st.state)->>'card_expires_first')::boolean then
        perform billing.outbox_put(a.id, 'card_expiring', null, (billing.active_method(a.id)).id::text,
          'card_expiring:' || (billing.active_method(a.id)).id || ':' || extract(epoch from st.period_end)::bigint,
          p_at, st.period_end, p_at);
      end if;
    end if;
  end loop;
  select count(*) into n from billing.outbox where status = 'queued';
  return jsonb_build_object('queued', n);
end $function$;
