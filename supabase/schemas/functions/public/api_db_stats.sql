CREATE OR REPLACE FUNCTION public.api_db_stats(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'aggRows', s.agg_rows, 'days', s.days,
    'first', case when s.first_ts is null then null
                  else to_char(to_timestamp(s.first_ts) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') end,
    'last',  case when s.last_ts is null then null
                  else to_char(to_timestamp(s.last_ts) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') end,
    'perInverterRows', s.per_inverter_rows,
    'rawSnapshots', 0, 'rawBytesUncompressed', 0, 'rawBytesGzipped', 0)
  from public.q_stats(public.my_plant(p_plant)) s
$function$;
