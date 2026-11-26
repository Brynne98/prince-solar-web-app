CREATE OR REPLACE FUNCTION private.billing_year_paid_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  if new.plan = 'free' or new.comped then
    new.prepaid_on := null;
    return new;
  end if;
  if old.prepaid_on is not null and new.prepaid_on is not null
     and ((new.plan, new.period, new.extra_plants, new.next_period, new.next_extra_plants)
            is distinct from (old.plan, old.period, old.extra_plants, old.next_period, old.next_extra_plants)
          or (new.next_plan is distinct from old.next_plan and new.next_plan is not null and new.next_plan <> 'free')) then
    raise exception 'your year is paid: the plan stays until it starts' using errcode = '22023';
  end if;
  return new;
end $function$;
