-- ============================================================================
-- 0192 — A plant linked stopped keeps SunSynk's zone and location (SOLAR-481).
--
-- A plant linked while the plan is full links stopped, and got no plant_config
-- row. Started later, plant_start_fill seeded a bare row: Africa/Johannesburg,
-- no lat/lon. A plant outside UTC+2 then read hours old, and No readings fired.
--
-- seedPlants (sunsynk.ts) now seeds a stopped plant's row at link time, from
-- SunSynk's plant detail, with 'paused': true. Such a row gets no history
-- bookmarks: the state a plant stopped after collecting is in. Inserting them
-- empty, not clearing them after, keeps email_on_history from sending a
-- "history ready" email for a plant that collects nothing.
-- plant_start_fill is unchanged: it finds the row and sets the bookmarks in the
-- plant's own zone. Its bare-row branch stays for a link whose detail call failed.
-- Body is 0054's plus the paused case.
-- ============================================================================

create or replace function public.plant_config_seed(p_rows jsonb)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.plant_config (plant_id, timezone, currency, lat, lon, panel_azimuth, geometry_source,
                                   backfill_next, backfill_until, temp_next)
  select (r->>'plant_id')::bigint,
         tz,
         coalesce(nullif(upper(r->>'currency'), ''), 'ZAR'),
         nullif(r->>'lat', '')::double precision,
         nullif(r->>'lon', '')::double precision,
         case when nullif(r->>'lat', '')::double precision > 0 then 180 else 0 end,
         'default',
         case when not paused then (now() at time zone tz)::date - 60 end,
         case when not paused then (now() at time zone tz)::date - 14 end,
         case when not paused then (now() at time zone tz)::date - 60 end
    from jsonb_array_elements(p_rows) r,
         lateral (select coalesce(nullif(r->>'timezone', ''), 'Africa/Johannesburg') as tz,
                         coalesce((r->>'paused')::boolean, false) as paused) z
  on conflict (plant_id) do nothing
$$;
