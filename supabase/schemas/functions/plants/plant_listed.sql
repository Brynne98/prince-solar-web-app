CREATE OR REPLACE FUNCTION plants.plant_listed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare uid uuid;
begin
  if tg_table_name = 'claims' then
    uid := (select a.user_id from billing.accounts a where a.id = new.account);
  else
    uid := (select l.user_id from plants.logins l where l.id = new.login and l.kind = 'login');
  end if;
  -- the plant's history is ready already: this account's one mail (SOLAR-686 H17)
  if uid is not null and exists (select 1 from public.plant_config c where c.plant_id = new.plant) and history.ready(new.plant) then
    insert into public.email_queue (user_id, plant_id, kind, key, priority)
    values (uid, new.plant, 'history', 'history:' || new.plant, 1)
    on conflict do nothing;
  end if;
  return null;
end $function$;
