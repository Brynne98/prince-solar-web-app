CREATE OR REPLACE FUNCTION billing.final_choice(p_account uuid, p_plants bigint[], p_places integer)
 RETURNS bigint[]
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare want bigint[]; bad bigint;
begin
  if p_plants is null then raise exception 'choose the plants first' using errcode = '22023'; end if;
  want := array(select distinct x from unnest(p_plants) x order by 1);
  select x into bad from unnest(want) x where not billing.has_route(p_account, x, false)
     and not exists (select 1 from billing.seats se where se.account = p_account and se.plant = x and se.closed_at is null)
   limit 1;
  if found then raise exception 'plant % is not on this account''s logins', bad using errcode = '22023'; end if;
  -- 0277: not chosen now and its old history still being deleted
  select x into bad from unnest(want) x where private.history_deleting(x)
     and not exists (select 1 from billing.seats se where se.account = p_account and se.plant = x and se.closed_at is null)
   limit 1;
  if found then raise exception 'history of plant % is still being deleted', bad using errcode = '22023'; end if;
  if cardinality(want) > p_places then
    raise exception 'that plan has % places', p_places using errcode = '22023';
  end if;
  return want;
end $function$;
