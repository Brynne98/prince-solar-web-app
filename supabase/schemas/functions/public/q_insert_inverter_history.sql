CREATE OR REPLACE FUNCTION public.q_insert_inverter_history(p_plant bigint, p_sn text, p_rows jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare n integer;
begin
  with src as (
    -- one row per ts (ON CONFLICT cannot touch a row twice); duplicates merge per field
    select (r->>'ts')::bigint                  as ts,
           max(nullif(r->>'ac', '')::real)    as ac_c,
           max(nullif(r->>'dc', '')::real)    as dc_c,
           max(nullif(r->>'vac', '')::real)   as vac_v,
           max(nullif(r->>'fac', '')::real)   as fac_hz,
           max(nullif(r->>'gfac', '')::real)  as grid_fac_hz
      from jsonb_array_elements(p_rows) r
     where (r->>'ts') ~ '^\d+$'
     group by 1
  ),
  ins as (
    insert into public.inverter_history as h (plant_id, sn, ts, ac_c, dc_c, vac_v, fac_hz, grid_fac_hz)
    select p_plant, p_sn, ts, ac_c, dc_c, vac_v, fac_hz, grid_fac_hz from src
    on conflict (sn, ts) do update
      set ac_c        = coalesce(excluded.ac_c,        h.ac_c),
          dc_c        = coalesce(excluded.dc_c,        h.dc_c),
          vac_v       = coalesce(excluded.vac_v,       h.vac_v),
          fac_hz      = coalesce(excluded.fac_hz,      h.fac_hz),
          grid_fac_hz = coalesce(excluded.grid_fac_hz, h.grid_fac_hz),
          plant_id    = excluded.plant_id
      where (h.plant_id, h.ac_c, h.dc_c, h.vac_v, h.fac_hz, h.grid_fac_hz)
            is distinct from
            (excluded.plant_id,
             coalesce(excluded.ac_c,        h.ac_c),
             coalesce(excluded.dc_c,        h.dc_c),
             coalesce(excluded.vac_v,       h.vac_v),
             coalesce(excluded.fac_hz,      h.fac_hz),
             coalesce(excluded.grid_fac_hz, h.grid_fac_hz))
    returning 1)
  select count(*) into n from ins;
  return n;
end $function$;
