CREATE OR REPLACE FUNCTION history.start(p_plant bigint, p_account uuid, p_reason text, p_pace_s integer DEFAULT 0, p_fetch_no integer DEFAULT 0, p_at timestamp with time zone DEFAULT now())
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  accs uuid[];
  imp bigint;
  tz text := plants.tz(p_plant);
  top date;
  n int := history.days_back();
begin
  if p_reason not in ('link', 'restart', 'switch') then
    raise exception 'history.start: unknown reason %', p_reason;
  end if;
  if private.history_deleting(p_plant) then return null; end if;
  if p_account is null then
    accs := array(select distinct r.account from billing.reading_routes(p_at) r where r.plant = p_plant order by 1);
  elsif billing.holds_plant(p_account, p_plant, p_at) then
    accs := array[p_account];
  end if;
  if coalesce(cardinality(accs), 0) = 0 then return null; end if;
  top := (p_at at time zone tz)::date - 1;

  select i.id into imp from history.imports i where i.plant = p_plant and i.status = 'open' for update;
  if imp is null then
    insert into history.imports (plant, reason, requested_at, floor_day, top_day)
    values (p_plant, p_reason, p_at, top - (n - 1), top) returning id into imp;
    -- newest first (H5): the walk orders by day; a gap or check row already open joins the import
    insert into history.days as d (plant, import, day, kind, why, due_at)
    select p_plant, imp, top - g, k, 'import', p_at
      from generate_series(0, n - 1) g cross join (values ('minutes'), ('extras')) x(k)
    on conflict (plant, day, kind) where status = 'queued'
    do update set import = excluded.import, why = 'import', grid_only = false;
    -- the kWh totals back to the first year (H2)
    insert into history.totals as t (plant, full_sweep, due_at) values (p_plant, true, p_at)
    on conflict (plant) do update set full_sweep = true, due_at = least(t.due_at, excluded.due_at);
  end if;
  insert into history.import_accounts as a (import, account, reason, pace_s, fetch_no, requested_at)
  select imp, x, p_reason, greatest(coalesce(p_pace_s, 0), 0), coalesce(p_fetch_no, 0), p_at from unnest(accs) x
  on conflict (import, account) do update
     set reason = excluded.reason, pace_s = excluded.pace_s, fetch_no = excluded.fetch_no,
         requested_at = excluded.requested_at, left_at = null;
  return imp;
end $function$;
