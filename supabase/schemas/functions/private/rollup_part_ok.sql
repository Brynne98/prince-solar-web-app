CREATE OR REPLACE FUNCTION private.rollup_part_ok(p_oid oid, p_name text, p_parent text, p_lo bigint, p_hi bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_temp'
AS $function$
  select coalesce(to_regclass(format('public.%I', p_name)) = p_oid, false)
     and exists (select 1 from pg_inherits i join pg_class ch on ch.oid = i.inhrelid
                  where ch.oid = p_oid and i.inhparent = format('public.%I', p_parent)::regclass
                    and private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'FROM') = p_lo
                    and private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'TO')   = p_hi)
$function$;
