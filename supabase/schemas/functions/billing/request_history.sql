CREATE OR REPLACE FUNCTION billing.request_history(p_account uuid, p_plants bigint[], p_at timestamp with time zone, p_counts boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  n int;
  target int;
  counted boolean;
begin
  if coalesce(cardinality(p_plants), 0) = 0 then return; end if;
  select (after->>'fetch_no')::int, coalesce((after->>'counted')::boolean, true) into n, counted from billing.account_events
   where account = p_account and kind = 'history_fetch' and at = p_at order by id limit 1;
  if n is null then
    counted := p_counts;
    n := case when counted then
           1 + (select count(*) from billing.account_events
                 where account = p_account and kind = 'history_fetch' and at > p_at - interval '7 days' and at < p_at
                   and coalesce((after->>'counted')::boolean, true))
         else 0 end;
    perform billing.log_event(p_account, p_at, 'system', 'history_fetch', null,
                              jsonb_build_object('fetch_no', n, 'counted', counted, 'plants', to_jsonb(p_plants)));
  end if;
  target := case when n <= 3 then 0 else least(1200 * power(2, least(n - 4, 10)), 86400)::int end;
  update billing.history_fetches set status = 'dropped', drop_reason = 'replaced', finished_at = p_at, claimed_until = null
   where account = p_account and plant = any (p_plants) and status in ('queued', 'running');
  insert into billing.history_fetches (account, plant, fetch_no, target_s, requested_at)
  select p_account, x, n, target, p_at from unnest(p_plants) x;
end $function$;
