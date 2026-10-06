-- SOLAR-43: exact rows per big table and plant, for bytes-per-row. Read-only.
select tbl, plant_id, rows, inverters, first_day, last_day from (
  select 'readings_y2026m09' tbl, plant_id, count(*) rows, count(distinct sn) inverters, min(to_timestamp(ts))::date first_day, max(to_timestamp(ts))::date last_day from public.readings_y2026m09 group by 2
  union all select 'strings_y2026m09', plant_id, count(*), count(distinct sn), min(to_timestamp(ts))::date, max(to_timestamp(ts))::date from public.strings_y2026m09 group by 2
  union all select 'agg_minute', plant_id, count(*), null, min(to_timestamp(ts))::date, max(to_timestamp(ts))::date from public.agg_minute group by 2
  union all select 'inverter_history', plant_id, count(*), count(distinct sn), min(to_timestamp(ts))::date, max(to_timestamp(ts))::date from public.inverter_history group by 2
  union all select 'solar_forecast', null, count(*), null, min(to_timestamp(ts))::date, max(to_timestamp(ts))::date from public.solar_forecast
  union all select 'plant_energy', plant_id, count(*), null, min(period), max(period) from public.plant_energy group by 2
) x order by 1, 2
