CREATE OR REPLACE FUNCTION billing.outbox_on_purge()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare se record;
begin
  if new.history_purged_at is not null and old.history_purged_at is null then
    for se in select s.account from billing.seats s where s.plant = new.id and s.closed_at is null loop
      perform billing.outbox_put(se.account, 'history_deleted', null, new.id::text,
                                 'history_deleted:' || se.account || ':' || new.id || ':' || extract(epoch from new.history_purged_at)::bigint,
                                 new.history_purged_at, new.history_purged_at + interval '2 days', new.history_purged_at);
    end loop;
  end if;
  return null;
end $function$;
