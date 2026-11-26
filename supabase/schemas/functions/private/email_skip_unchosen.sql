CREATE OR REPLACE FUNCTION private.email_skip_unchosen()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare acc uuid;
begin
  if new.user_id is null then return new; end if;
  select id into acc from billing.accounts where user_id = new.user_id;
  if new.plant_id is not null and not exists (select 1 from billing.seats s where s.account = acc and s.plant = new.plant_id
                                                 and s.closed_at is null) then
    return null;
  end if;
  if new.kind like 'report\_%' and not billing.report_wanted(acc, new.plant_id) then return null; end if;
  if new.plant_id is not null and (private.is_alert(new.kind) or new.kind in ('share_down', 'share_back'))
     and not private.plant_live(new.user_id, new.plant_id) then
    return null;
  end if;
  return new;
end $function$;
