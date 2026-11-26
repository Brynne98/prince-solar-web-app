CREATE OR REPLACE FUNCTION private.ensure_day_partition(p_parent text, p_day date)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'pg_temp'
AS $function$
declare
  lo bigint := extract(epoch from p_day::timestamp at time zone 'UTC')::bigint;
  child text := format('%s_d%s', p_parent, to_char(p_day, 'YYYYMMDD'));
begin
  -- already covered, by a day partition or a monthly one not yet split
  if exists (
    select 1 from pg_inherits i join pg_class c on c.oid = i.inhrelid
     where i.inhparent = ('public.' || p_parent)::regclass
       and private.partbound_epoch(pg_get_expr(c.relpartbound, c.oid), 'FROM') <= lo
       and private.partbound_epoch(pg_get_expr(c.relpartbound, c.oid), 'TO')   >  lo) then
    return false;
  end if;
  execute format('create table public.%I partition of public.%I for values from (%s) to (%s)',
    child, p_parent, lo, lo + 86400);
  execute format('alter table public.%I enable row level security', child);
  execute format('revoke all on public.%I from anon, authenticated', child);
  return true;
end $function$;
