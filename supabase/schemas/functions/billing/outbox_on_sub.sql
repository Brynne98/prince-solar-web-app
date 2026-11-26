CREATE OR REPLACE FUNCTION billing.outbox_on_sub()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  if new.status = 'ended' and old.status is distinct from 'ended' then
    -- keyed and stamped with this ending, so a plan brought back that ends again has its own email
    insert into billing.outbox (account, key, ref, ended_at, dedupe_key, not_before, created_at)
    select new.account, 'plan_ended', new.id::text, new.ended_at,
           'plan_ended:' || new.id || ':' || (extract(epoch from new.ended_at) * 1000)::bigint,
           greatest(new.ended_at, now()), now()
     where new.account is not null
    on conflict (dedupe_key) do nothing;
  end if;
  return null;
end $function$;
